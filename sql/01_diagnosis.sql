-- 01_diagnosis.sql
-- every integrity check, as a view in the dq schema so it can be re-run at any time.
-- each view returns the offending rows. dq.findings rolls them up into one ranked list,
-- and dq.findings_baseline keeps the counts from the very first run, before cleanup.
--
-- money is in ghana cedis. "value" means the figure that would be wrong in a report
-- if the fault were left alone, not money already lost.

-- 1. products showing less than zero in stock. stock can't physically be negative,
-- so every one of these is a unit sold that never existed.
CREATE OR REPLACE VIEW dq.chk_negative_stock AS
SELECT product_id, product_name, stock_quantity, price,
       -stock_quantity * price AS value_oversold
FROM products
WHERE stock_quantity < 0;

-- 2. stock on the shelf (products.stock_quantity) against the sum of every movement in the
-- log. for most products the two agree exactly, so the log is meant to be the history of
-- the stock figure. where they disagree we try to explain why.
CREATE OR REPLACE VIEW dq.chk_stock_vs_ledger AS
WITH ledger AS (
    SELECT product_id, sum(change_qty) AS ledger_qty
    FROM inventory_log
    GROUP BY product_id
),
duplicate_groups AS (
    SELECT product_id, change_qty, count(*) - 1 AS extra_copies
    FROM inventory_log
    GROUP BY product_id, change_qty, reason, created_at
    HAVING count(*) > 1
),
duplicate_effect AS (
    SELECT product_id, sum(change_qty * extra_copies) AS duplicate_qty
    FROM duplicate_groups
    GROUP BY product_id
),
unapplied AS (
    SELECT product_id, sum(change_qty) AS unapplied_qty
    FROM inventory_log
    WHERE note = 'recount, not applied'
    GROUP BY product_id
)
SELECT p.product_id,
       p.product_name,
       p.stock_quantity,
       coalesce(l.ledger_qty, 0) AS ledger_qty,
       p.stock_quantity - coalesce(l.ledger_qty, 0) AS difference,
       coalesce(d.duplicate_qty, 0) AS duplicate_qty,
       coalesce(u.unapplied_qty, 0) AS unapplied_qty,
       CASE
           WHEN p.stock_quantity = coalesce(l.ledger_qty, 0) - coalesce(d.duplicate_qty, 0)
               THEN 'duplicate log rows'
           WHEN p.stock_quantity = coalesce(l.ledger_qty, 0) - coalesce(u.unapplied_qty, 0)
               THEN 'recount logged but never applied'
           WHEN p.stock_quantity = coalesce(l.ledger_qty, 0) - coalesce(d.duplicate_qty, 0) - coalesce(u.unapplied_qty, 0)
               THEN 'both of the above'
           ELSE 'unexplained'
       END AS likely_cause,
       abs(p.stock_quantity - coalesce(l.ledger_qty, 0)) * p.price AS value_in_doubt
FROM products p
LEFT JOIN ledger l USING (product_id)
LEFT JOIN duplicate_effect d USING (product_id)
LEFT JOIN unapplied u USING (product_id)
WHERE p.stock_quantity IS DISTINCT FROM coalesce(l.ledger_qty, 0);

-- 3. the same order line entered twice. we only call it a double entry when the order's
-- own total agrees with the version that has the copy removed.
CREATE OR REPLACE VIEW dq.chk_duplicate_order_lines AS
WITH grouped AS (
    SELECT order_id, product_id, quantity, unit_price,
           count(*) AS copies,
           min(order_item_id) AS kept_item_id
    FROM order_items
    GROUP BY order_id, product_id, quantity, unit_price
    HAVING count(*) > 1
),
order_lines AS (
    SELECT order_id, sum(quantity * unit_price) AS line_total
    FROM order_items
    WHERE order_id IN (SELECT order_id FROM grouped)
    GROUP BY order_id
),
extra AS (
    SELECT order_id, sum(quantity * unit_price * (copies - 1)) AS extra_value
    FROM grouped
    GROUP BY order_id
)
SELECT g.order_id, g.product_id, g.quantity, g.unit_price, g.copies, g.kept_item_id,
       o.total_amount,
       ol.line_total,
       abs(o.total_amount - (ol.line_total - e.extra_value)) < 0.02 AS total_confirms_double_entry,
       g.quantity * g.unit_price * (g.copies - 1) AS value_double_counted
FROM grouped g
JOIN orders o USING (order_id)
JOIN order_lines ol USING (order_id)
JOIN extra e USING (order_id);

-- 4. order lines with no price, or a price of zero. where the order total matches the
-- list price, the customer paid and the line just lost its price.
CREATE OR REPLACE VIEW dq.chk_unpriced_order_lines AS
WITH flagged AS (
    SELECT DISTINCT order_id
    FROM order_items
    WHERE unit_price IS NULL OR unit_price = 0
),
repriced AS (
    SELECT oi.order_id,
           sum(oi.quantity * CASE WHEN oi.unit_price IS NULL OR oi.unit_price = 0 THEN p.price ELSE oi.unit_price END) AS repriced_total
    FROM order_items oi
    JOIN products p USING (product_id)
    WHERE oi.order_id IN (SELECT order_id FROM flagged)
    GROUP BY oi.order_id
)
SELECT oi.order_item_id, oi.order_id, oi.product_id, oi.quantity, oi.unit_price,
       p.price AS list_price,
       abs(o.total_amount - r.repriced_total) < 0.02 AS total_confirms_list_price,
       oi.quantity * p.price AS value_missing
FROM order_items oi
JOIN products p USING (product_id)
LEFT JOIN orders o USING (order_id)
LEFT JOIN repriced r USING (order_id)
WHERE oi.unit_price IS NULL OR oi.unit_price = 0;

-- 4b. quantities nobody orders. the biggest normal line in the data is 10 units; a few
-- say 999 or 9999, which looks like a placeholder or a slipped finger. the order's own
-- total shows what the real quantity was.
CREATE OR REPLACE VIEW dq.chk_implausible_quantities AS
WITH other_lines AS (
    SELECT oi.order_item_id,
           coalesce((SELECT sum(x.quantity * x.unit_price)
                       FROM order_items x
                      WHERE x.order_id = oi.order_id
                        AND x.order_item_id <> oi.order_item_id), 0) AS other_value
    FROM order_items oi
    WHERE oi.quantity > 100
)
SELECT oi.order_item_id, oi.order_id, oi.product_id, oi.quantity, oi.unit_price,
       o.total_amount,
       (o.total_amount - ol.other_value) / nullif(oi.unit_price, 0) AS implied_quantity,
       (o.total_amount - ol.other_value) / nullif(oi.unit_price, 0) >= 1
           AND abs((o.total_amount - ol.other_value) / nullif(oi.unit_price, 0)
                   - round((o.total_amount - ol.other_value) / nullif(oi.unit_price, 0))) < 0.001
           AS total_confirms_quantity,
       oi.quantity * oi.unit_price AS value_on_record
FROM order_items oi
JOIN other_lines ol USING (order_item_id)
JOIN orders o USING (order_id);

-- 5. order header total that disagrees with its own lines, for orders whose lines are
-- complete and have no copies (those are explained by checks 3 and 4).
CREATE OR REPLACE VIEW dq.chk_order_total_mismatch AS
WITH lines AS (
    SELECT order_id,
           sum(quantity * unit_price) AS line_total,
           bool_or(unit_price IS NULL OR unit_price = 0) AS has_unpriced
    FROM order_items
    GROUP BY order_id
)
SELECT o.order_id, o.total_amount, l.line_total,
       o.total_amount - l.line_total AS difference,
       round(o.total_amount / nullif(l.line_total, 0), 2) AS ratio
FROM orders o
JOIN lines l USING (order_id)
WHERE NOT l.has_unpriced
  AND o.order_id NOT IN (SELECT order_id FROM dq.chk_duplicate_order_lines)
  AND o.order_id NOT IN (SELECT order_id FROM dq.chk_implausible_quantities)
  AND abs(o.total_amount - l.line_total) > 0.01;

-- 6. status typed fifteen different ways. anything not already in the agreed spelling
-- is counted here.
CREATE OR REPLACE VIEW dq.chk_status_spellings AS
SELECT status, count(*) AS orders, sum(total_amount) AS value
FROM orders
WHERE status IS NULL
   OR status NOT IN ('pending', 'shipped', 'completed', 'cancelled', 'refunded')
GROUP BY status;

-- 7. orders for customers who don't exist.
CREATE OR REPLACE VIEW dq.chk_orders_unknown_customer AS
SELECT o.order_id, o.customer_id, o.order_date, o.status, o.total_amount
FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id);

-- 8. order lines whose order header is missing.
CREATE OR REPLACE VIEW dq.chk_items_unknown_order AS
SELECT oi.*, oi.quantity * coalesce(oi.unit_price, 0) AS line_value
FROM order_items oi
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = oi.order_id);

-- 9. the stock trail and the order book don't describe the same sales. per product,
-- units ordered against units the log says left as sales.
CREATE OR REPLACE VIEW dq.chk_trail_vs_orders AS
WITH ordered AS (
    SELECT oi.product_id, sum(oi.quantity) AS units_ordered
    FROM order_items oi
    JOIN orders o USING (order_id)
    WHERE lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'pending')
    GROUP BY oi.product_id
),
logged AS (
    SELECT product_id, -sum(change_qty) AS units_logged_as_sold
    FROM inventory_log
    WHERE reason = 'sale'
    GROUP BY product_id
)
SELECT p.product_id,
       coalesce(o.units_ordered, 0) AS units_ordered,
       coalesce(l.units_logged_as_sold, 0) AS units_logged_as_sold,
       coalesce(o.units_ordered, 0) - coalesce(l.units_logged_as_sold, 0) AS units_unaccounted
FROM products p
LEFT JOIN ordered o USING (product_id)
LEFT JOIN logged l USING (product_id)
WHERE coalesce(o.units_ordered, 0) <> coalesce(l.units_logged_as_sold, 0);

-- 10. orders dated after the extract ends (2026-08-31) or in the future.
CREATE OR REPLACE VIEW dq.chk_orders_after_as_of AS
SELECT order_id, customer_id, order_date, status, total_amount
FROM orders
WHERE order_date >= (SELECT report_as_of()) + 1;

-- 11. stock movements repeated exactly: same product, quantity, reason and second.
-- not all of these are mistakes. two customers can buy the same thing in the same second.
-- a repeat only counts as a proven double when the stock figure agrees with the log
-- once the copy is taken out (see dq.chk_stock_vs_ledger).
CREATE OR REPLACE VIEW dq.chk_log_duplicates AS
SELECT l.product_id, l.change_qty, l.reason, l.created_at,
       count(*) AS copies,
       array_agg(l.log_id ORDER BY l.log_id) AS log_ids,
       l.product_id IN (
           SELECT s.product_id
           FROM dq.chk_stock_vs_ledger s
           WHERE s.likely_cause IN ('duplicate log rows', 'both of the above')
       ) AS proven_double
FROM inventory_log l
GROUP BY l.product_id, l.change_qty, l.reason, l.created_at
HAVING count(*) > 1;

-- 12. stock movements for products that don't exist.
CREATE OR REPLACE VIEW dq.chk_log_unknown_product AS
SELECT l.*
FROM inventory_log l
WHERE NOT EXISTS (SELECT 1 FROM products p WHERE p.product_id = l.product_id);

-- 13. corrections with a note nobody can check later ("??", "see whatsapp msg").
CREATE OR REPLACE VIEW dq.chk_unexplained_corrections AS
SELECT log_id, product_id, change_qty, created_at, note
FROM inventory_log
WHERE reason = 'correction'
  AND (note IS NULL OR note IN ('', '??', 'see WhatsApp msg', 'POS mismatch'));

-- 14. categories whose parent chain loops back on itself, or points at nothing.
-- walking up from every category, a loop is the walk coming back to where it started.
CREATE OR REPLACE VIEW dq.chk_category_tree AS
WITH RECURSIVE up AS (
    SELECT category_id AS start_id, category_id, parent_id
    FROM categories
    UNION ALL
    SELECT up.start_id, c.category_id, c.parent_id
    FROM up
    JOIN categories c ON c.category_id = up.parent_id
) CYCLE category_id SET is_cycle USING walked
SELECT DISTINCT c.category_id, c.category_name, c.parent_id, 'part of a loop' AS problem
FROM up
JOIN categories c ON c.category_id = up.start_id
WHERE up.is_cycle
UNION ALL
SELECT c.category_id, c.category_name, c.parent_id, 'parent does not exist'
FROM categories c
WHERE c.parent_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM categories p WHERE p.category_id = c.parent_id);

-- 15. products with no category at all. they disappear from any category rollup.
CREATE OR REPLACE VIEW dq.chk_products_no_category AS
SELECT product_id, product_name, stock_quantity
FROM products
WHERE category_id IS NULL
  AND product_name NOT LIKE 'RACE TEST FIXTURE%';

-- 16. the same email on more than one customer record. probably the same person twice,
-- which splits their spend and pushes them down the ranking.
CREATE OR REPLACE VIEW dq.chk_duplicate_customers AS
SELECT lower(trim(email)) AS email_key,
       count(*) AS records,
       array_agg(customer_id ORDER BY customer_id) AS customer_ids,
       array_agg(trim(full_name) ORDER BY customer_id) AS names
FROM customers
GROUP BY lower(trim(email))
HAVING count(*) > 1;

-- the ranked summary. ranking is by danger to the business, not by row count.
CREATE OR REPLACE VIEW dq.findings AS
SELECT 1 AS danger_rank, 'negative stock (oversold units)' AS finding,
       (SELECT count(*) FROM dq.chk_negative_stock) AS rows_affected,
       (SELECT coalesce(sum(value_oversold), 0) FROM dq.chk_negative_stock) AS value_ghs
UNION ALL
SELECT 2, 'stock trail does not match the order book',
       (SELECT count(*) FROM dq.chk_trail_vs_orders),
       NULL
UNION ALL
SELECT 3, 'stock figure disagrees with its own movement log',
       (SELECT count(*) FROM dq.chk_stock_vs_ledger),
       (SELECT coalesce(sum(value_in_doubt), 0) FROM dq.chk_stock_vs_ledger)
UNION ALL
SELECT 4, 'order lines with impossible quantities (999, 9999)',
       (SELECT count(*) FROM dq.chk_implausible_quantities),
       (SELECT coalesce(sum(value_on_record), 0) FROM dq.chk_implausible_quantities)
UNION ALL
SELECT 5, 'order total disagrees with its lines',
       (SELECT count(*) FROM dq.chk_order_total_mismatch),
       (SELECT coalesce(sum(abs(difference)), 0) FROM dq.chk_order_total_mismatch)
UNION ALL
SELECT 6, 'order status spelled inconsistently',
       (SELECT coalesce(sum(orders), 0) FROM dq.chk_status_spellings),
       (SELECT coalesce(sum(value), 0) FROM dq.chk_status_spellings)
UNION ALL
SELECT 7, 'order lines entered twice',
       (SELECT count(*) FROM dq.chk_duplicate_order_lines WHERE total_confirms_double_entry),
       (SELECT coalesce(sum(value_double_counted), 0) FROM dq.chk_duplicate_order_lines WHERE total_confirms_double_entry)
UNION ALL
SELECT 8, 'order lines with no price or zero price',
       (SELECT count(*) FROM dq.chk_unpriced_order_lines),
       (SELECT coalesce(sum(value_missing), 0) FROM dq.chk_unpriced_order_lines)
UNION ALL
SELECT 9, 'order lines with no order',
       (SELECT count(*) FROM dq.chk_items_unknown_order),
       (SELECT coalesce(sum(line_value), 0) FROM dq.chk_items_unknown_order)
UNION ALL
SELECT 10, 'orders for customers who do not exist',
       (SELECT count(*) FROM dq.chk_orders_unknown_customer),
       (SELECT coalesce(sum(total_amount), 0) FROM dq.chk_orders_unknown_customer)
UNION ALL
SELECT 11, 'orders dated after the extract ends',
       (SELECT count(*) FROM dq.chk_orders_after_as_of),
       (SELECT coalesce(sum(total_amount), 0) FROM dq.chk_orders_after_as_of)
UNION ALL
SELECT 12, 'stock movements logged twice (proven; flagged, never deleted)',
       (SELECT coalesce(sum(copies - 1), 0) FROM dq.chk_log_duplicates WHERE proven_double),
       NULL
UNION ALL
SELECT 13, 'corrections with no usable reason',
       (SELECT count(*) FROM dq.chk_unexplained_corrections),
       NULL
UNION ALL
SELECT 14, 'category tree loops or dead ends',
       (SELECT count(*) FROM dq.chk_category_tree),
       NULL
UNION ALL
SELECT 15, 'duplicate customer records (same email)',
       (SELECT coalesce(sum(records), 0) FROM dq.chk_duplicate_customers),
       NULL
UNION ALL
SELECT 16, 'stock movements for unknown products',
       (SELECT count(*) FROM dq.chk_log_unknown_product),
       NULL
UNION ALL
SELECT 17, 'products with no category',
       (SELECT count(*) FROM dq.chk_products_no_category),
       NULL;

-- keep the first-run numbers so the effect of cleanup can be shown later.
CREATE TABLE IF NOT EXISTS dq.findings_baseline (
    danger_rank    integer PRIMARY KEY,
    finding        text NOT NULL,
    rows_affected  bigint,
    value_ghs      numeric,
    captured_at    timestamptz NOT NULL DEFAULT now()
);

INSERT INTO dq.findings_baseline (danger_rank, finding, rows_affected, value_ghs)
SELECT danger_rank, finding, rows_affected, value_ghs
FROM dq.findings
ON CONFLICT (danger_rank) DO NOTHING;

CREATE OR REPLACE VIEW dq.findings_before_after AS
SELECT b.danger_rank, b.finding,
       b.rows_affected AS rows_before,
       f.rows_affected AS rows_now,
       b.value_ghs AS value_before
FROM dq.findings_baseline b
JOIN dq.findings f USING (danger_rank);
