-- 03_cleanup.sql
-- fixes that are safe to make. the rule throughout: only change a row when the data itself
-- proves what the right value is, and keep a copy of every row we change or remove in dq.
-- anything we can't prove stays as it is and is flagged instead.

-- quarantine tables: the original rows, plus why they were taken out.
CREATE TABLE IF NOT EXISTS dq.removed_order_items (
    LIKE order_items,
    removed_reason  text NOT NULL,
    removed_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (order_item_id)
);

CREATE TABLE IF NOT EXISTS dq.order_status_original (
    order_id         integer PRIMARY KEY,
    original_status  text
);

CREATE TABLE IF NOT EXISTS dq.order_item_price_fixes (
    order_item_id   integer PRIMARY KEY,
    old_unit_price  numeric(12,2),
    new_unit_price  numeric(12,2) NOT NULL,
    fixed_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS dq.category_fixes (
    category_id     integer PRIMARY KEY,
    old_parent_id   integer,
    new_parent_id   integer,
    reason          text NOT NULL
);

-- 1. order status: one spelling per meaning. the original text is kept so nothing is lost.
INSERT INTO dq.order_status_original (order_id, original_status)
SELECT order_id, status
FROM orders
WHERE status IS DISTINCT FROM CASE lower(trim(status))
                                  WHEN 'complete' THEN 'completed'
                                  WHEN 'canceled' THEN 'cancelled'
                                  ELSE lower(trim(status))
                              END
ON CONFLICT (order_id) DO NOTHING;

UPDATE orders
SET status = CASE lower(trim(status))
                 WHEN 'complete' THEN 'completed'
                 WHEN 'canceled' THEN 'cancelled'
                 ELSE lower(trim(status))
             END
WHERE status IS DISTINCT FROM CASE lower(trim(status))
                                  WHEN 'complete' THEN 'completed'
                                  WHEN 'canceled' THEN 'cancelled'
                                  ELSE lower(trim(status))
                              END;

-- 2. order lines entered twice. the copy is removed only where the order's own total
-- confirms it was a double entry. the other repeats are left, they look like real
-- "add one more" lines.
INSERT INTO dq.removed_order_items
SELECT oi.*, 'double entry: order total matches the order without this copy'
FROM order_items oi
JOIN dq.chk_duplicate_order_lines d
  ON d.order_id = oi.order_id
 AND d.product_id = oi.product_id
 AND d.quantity = oi.quantity
 AND d.unit_price = oi.unit_price
WHERE d.total_confirms_double_entry
  AND oi.order_item_id <> d.kept_item_id
ON CONFLICT (order_item_id) DO NOTHING;

DELETE FROM order_items oi
USING dq.removed_order_items r
WHERE r.order_item_id = oi.order_item_id;

-- 3. lines that lost their price. where the order total matches the list price, put the
-- list price back. the rest stay unpriced and stay on the findings list.
INSERT INTO dq.order_item_price_fixes (order_item_id, old_unit_price, new_unit_price)
SELECT order_item_id, unit_price, list_price
FROM dq.chk_unpriced_order_lines
WHERE total_confirms_list_price
ON CONFLICT (order_item_id) DO NOTHING;

UPDATE order_items oi
SET unit_price = f.new_unit_price
FROM dq.order_item_price_fixes f
WHERE f.order_item_id = oi.order_item_id
  AND oi.unit_price IS DISTINCT FROM f.new_unit_price;

-- 4. impossible quantities (999, 9999). where the order total pins down the real
-- quantity as a whole number, use it. the original is kept in dq.order_item_quantity_fixes.
CREATE TABLE IF NOT EXISTS dq.order_item_quantity_fixes (
    order_item_id  integer PRIMARY KEY,
    old_quantity   integer NOT NULL,
    new_quantity   integer NOT NULL,
    fixed_at       timestamptz NOT NULL DEFAULT now()
);

INSERT INTO dq.order_item_quantity_fixes (order_item_id, old_quantity, new_quantity)
SELECT order_item_id, quantity, round(implied_quantity)::integer
FROM dq.chk_implausible_quantities
WHERE total_confirms_quantity
ON CONFLICT (order_item_id) DO NOTHING;

UPDATE order_items oi
SET quantity = f.new_quantity
FROM dq.order_item_quantity_fixes f
WHERE f.order_item_id = oi.order_item_id
  AND oi.quantity <> f.new_quantity;

-- 5. order lines whose order doesn't exist. with no customer and no date they can't go in
-- any report, and they block the link between lines and orders. they're moved out, not
-- destroyed, in case the missing orders turn up.
INSERT INTO dq.removed_order_items
SELECT oi.*, 'no matching order'
FROM order_items oi
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = oi.order_id)
ON CONFLICT (order_item_id) DO NOTHING;

DELETE FROM order_items oi
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = oi.order_id);

-- 6. the category loop. "seasonal promotions" and "promotions" each claimed the other as
-- parent. promotions is the broader one, so it becomes a top-level category and seasonal
-- promotions sits under it. "clearance" pointed at a category that doesn't exist and
-- becomes top level.
--
-- this is a one-off repair of the loop found in this extract, so it names the categories.
-- it can't recur: 04_constraints.sql adds a trigger that refuses any new loop, and
-- dq.chk_category_tree would list one if it ever got in another way. the dead-end rule
-- below is general and handles any parent that doesn't exist.
INSERT INTO dq.category_fixes (category_id, old_parent_id, new_parent_id, reason)
SELECT category_id, parent_id, NULL::integer, 'part of a loop with seasonal promotions, made top level'
FROM categories
WHERE category_name = 'Promotions'
  AND parent_id IN (SELECT category_id FROM categories WHERE category_name = 'Seasonal Promotions')
UNION ALL
SELECT category_id, parent_id, NULL, 'parent category does not exist, made top level'
FROM categories c
WHERE parent_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM categories p WHERE p.category_id = c.parent_id)
ON CONFLICT (category_id) DO NOTHING;

UPDATE categories c
SET parent_id = f.new_parent_id
FROM dq.category_fixes f
WHERE f.category_id = c.category_id
  AND c.parent_id IS DISTINCT FROM f.new_parent_id;

-- 7. stock movements logged twice. only proven doubles are flagged: repeats where the
-- stock figure agrees with the log once the copy is taken out. the other repeats agree
-- with stock as they are, and look like two real sales in the same second. flagged rows
-- stay in the table because an auditor needs to see that they were there.
UPDATE inventory_log l
SET is_duplicate = true
FROM dq.chk_log_duplicates d
WHERE d.proven_double
  AND l.product_id = d.product_id
  AND l.change_qty = d.change_qty
  AND l.reason = d.reason
  AND l.created_at = d.created_at
  AND l.log_id <> d.log_ids[1]
  AND NOT l.is_duplicate;

-- not touched, on purpose:
--   order header totals that disagree with their lines. the lines are what the customer
--   bought at the price of the day, so reports use the lines. the header stays as written.
--   orders for unknown customers and orders dated after the extract: real money, unknown
--   owner or date. they stay and the reports leave them out.
--   duplicate customer emails: could be two people sharing an address. flagged, not merged.
--   negative stock: fixed in 05, through the stock routine, so the fix is itself logged.
