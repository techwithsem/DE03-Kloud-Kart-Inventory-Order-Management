-- 07_indexes.sql
-- the original database has no indexes beyond primary keys. each one below is here for a
-- reason we measured (see docs/measurement_report.md), not added on spec.

-- finding a customer's orders, in date order. used by the report refresh, by any
-- "show me this customer" screen, and by the customer foreign key.
CREATE INDEX IF NOT EXISTS orders_customer_date_idx
    ON orders (customer_id, order_date);

-- finding an order's lines. every join from orders to order_items needs this, and so does
-- the order foreign key on delete.
CREATE INDEX IF NOT EXISTS order_items_order_idx
    ON order_items (order_id);

-- finding every sale of a product. the race test cleans up by product, and the product
-- foreign key checks this on every delete.
CREATE INDEX IF NOT EXISTS order_items_product_idx
    ON order_items (product_id);

-- a product's stock history in time order. this is the auditor's main question.
CREATE INDEX IF NOT EXISTS inventory_log_product_time_idx
    ON inventory_log (product_id, created_at);

-- the movements behind an order. without it, deleting or cancelling an order scans all
-- 280k log rows to clear the link.
CREATE INDEX IF NOT EXISTS inventory_log_order_idx
    ON inventory_log (order_id)
    WHERE order_id IS NOT NULL;

-- walking the category tree from parent to children, and products by category.
CREATE INDEX IF NOT EXISTS categories_parent_idx
    ON categories (parent_id);

CREATE INDEX IF NOT EXISTS products_category_idx
    ON products (category_id);

-- the handful of order lines with impossible quantities. the report checks every order
-- against this list. an index holding only those few rows makes the check cheap, where
-- without it the report reads all 336k lines a second time (measured: about 0.6 s).
CREATE INDEX IF NOT EXISTS order_items_implausible_qty_idx
    ON order_items (order_id)
    WHERE quantity > 100;
