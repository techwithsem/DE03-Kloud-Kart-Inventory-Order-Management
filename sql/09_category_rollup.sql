-- 09_category_rollup.sql
-- low stock at a glance, rolled up through the category tree to whatever depth it has.
--
-- a product counts towards its own category and every category above it, so
-- "electronics" shows the low-stock count for everything under electronics, at any depth.
-- the tree is walked with a recursive query, so new subcategories just appear. nothing
-- here knows how deep the tree goes.
--
-- each product sits in exactly one category and each category has one parent, so every
-- (ancestor, product) pair turns up once: no double counting. the cycle clause is a guard
-- in case a loop ever gets back in; a trigger on categories already blocks new ones.
--
-- products with no category are grouped under "uncategorised" so they can't go missing.

CREATE OR REPLACE VIEW v_category_paths AS
WITH RECURSIVE down AS (
    SELECT c.category_id,
           c.category_name,
           c.parent_id,
           1 AS depth,
           c.category_name::text AS path
    FROM categories c
    WHERE c.parent_id IS NULL
    UNION ALL
    SELECT c.category_id,
           c.category_name,
           c.parent_id,
           d.depth + 1,
           d.path || ' > ' || c.category_name
    FROM down d
    JOIN categories c ON c.parent_id = d.category_id
) CYCLE category_id SET is_cycle USING walked
SELECT category_id, category_name, parent_id, depth, path
FROM down
WHERE NOT is_cycle;

-- every category paired with itself and every category below it.
CREATE OR REPLACE VIEW v_category_descendants AS
WITH RECURSIVE tree AS (
    SELECT c.category_id AS ancestor_id,
           c.category_id AS descendant_id
    FROM categories c
    UNION ALL
    SELECT t.ancestor_id,
           c.category_id
    FROM tree t
    JOIN categories c ON c.parent_id = t.descendant_id
) CYCLE descendant_id SET is_cycle USING walked
SELECT ancestor_id, descendant_id
FROM tree
WHERE NOT is_cycle;

CREATE OR REPLACE VIEW v_low_stock_by_category AS
WITH product_state AS (
    SELECT p.product_id,
           p.category_id,
           p.stock_quantity,
           p.stock_quantity = 0 AS is_out,
           p.stock_quantity > 0 AND p.stock_quantity <= p.reorder_level AS is_low
    FROM products p
    WHERE p.product_name NOT LIKE 'RACE TEST FIXTURE%'
),
rolled_up AS (
    SELECT d.ancestor_id AS category_id,
           count(ps.product_id) AS products,
           count(*) FILTER (WHERE ps.is_out) AS out_of_stock,
           count(*) FILTER (WHERE ps.is_low) AS low_stock,
           coalesce(sum(ps.stock_quantity), 0) AS units_on_hand
    FROM v_category_descendants d
    LEFT JOIN product_state ps ON ps.category_id = d.descendant_id
    GROUP BY d.ancestor_id
)
SELECT cp.path AS category,
       cp.depth,
       r.category_id,
       r.products,
       r.out_of_stock,
       r.low_stock,
       r.out_of_stock + r.low_stock AS needs_attention,
       round(100.0 * (r.out_of_stock + r.low_stock) / nullif(r.products, 0), 1) AS pct_needs_attention,
       r.units_on_hand
FROM rolled_up r
JOIN v_category_paths cp USING (category_id)
UNION ALL
SELECT 'Uncategorised', 1, NULL,
       count(*),
       count(*) FILTER (WHERE is_out),
       count(*) FILTER (WHERE is_low),
       count(*) FILTER (WHERE is_out OR is_low),
       round(100.0 * count(*) FILTER (WHERE is_out OR is_low) / nullif(count(*), 0), 1),
       coalesce(sum(stock_quantity), 0)
FROM product_state
WHERE category_id IS NULL;

-- the products behind the numbers, for when a category needs looking into.
CREATE OR REPLACE VIEW v_low_stock_products AS
SELECT coalesce(cp.path, 'Uncategorised') AS category,
       p.product_id,
       p.product_name,
       p.stock_quantity,
       p.reorder_level,
       CASE WHEN p.stock_quantity = 0 THEN 'out of stock' ELSE 'low' END AS state
FROM products p
LEFT JOIN v_category_paths cp USING (category_id)
WHERE p.stock_quantity <= p.reorder_level
  AND p.product_name NOT LIKE 'RACE TEST FIXTURE%'
ORDER BY category, p.stock_quantity, p.product_name;
