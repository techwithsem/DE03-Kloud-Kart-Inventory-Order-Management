-- 04_constraints.sql
-- needs: 03, because a rule can only be added once the rows that break it are fixed.
-- rules the database enforces from now on, so the faults we just found can't come back.
--
-- not valid means "check every new or changed row, but don't fail on the old ones".
-- it's used where old rows break the rule and we chose not to change them (see 03).
-- the old rows stay listed in the dq views.
--
-- drop-then-add keeps the file safe to re-run.

-- columns every row must have. the data already has a value in each of these on every
-- row, so nothing old breaks; this stops a new row arriving half-filled. order line prices
-- are the exception: seven old lines still have none (see dq.chk_unpriced_order_lines),
-- so new lines are covered by order_items_price_present below instead.
ALTER TABLE categories    ALTER COLUMN category_name  SET NOT NULL;
ALTER TABLE customers     ALTER COLUMN full_name      SET NOT NULL;
ALTER TABLE customers     ALTER COLUMN email          SET NOT NULL;
ALTER TABLE customers     ALTER COLUMN registered_at  SET NOT NULL;
ALTER TABLE products      ALTER COLUMN product_name   SET NOT NULL;
ALTER TABLE products      ALTER COLUMN price          SET NOT NULL;
ALTER TABLE products      ALTER COLUMN stock_quantity SET NOT NULL;
ALTER TABLE products      ALTER COLUMN created_at     SET NOT NULL;
ALTER TABLE orders        ALTER COLUMN customer_id    SET NOT NULL;
ALTER TABLE orders        ALTER COLUMN order_date     SET NOT NULL;
ALTER TABLE orders        ALTER COLUMN status         SET NOT NULL;
ALTER TABLE orders        ALTER COLUMN total_amount   SET NOT NULL;
ALTER TABLE order_items   ALTER COLUMN order_id       SET NOT NULL;
ALTER TABLE order_items   ALTER COLUMN product_id     SET NOT NULL;
ALTER TABLE order_items   ALTER COLUMN quantity       SET NOT NULL;
ALTER TABLE inventory_log ALTER COLUMN product_id     SET NOT NULL;
ALTER TABLE inventory_log ALTER COLUMN change_qty     SET NOT NULL;
ALTER TABLE inventory_log ALTER COLUMN reason         SET NOT NULL;
ALTER TABLE inventory_log ALTER COLUMN created_at     SET NOT NULL;

-- order status: only the five agreed values.
ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_status_valid;
ALTER TABLE orders
    ADD CONSTRAINT orders_status_valid
    CHECK (status IN ('pending', 'shipped', 'completed', 'cancelled', 'refunded'));

ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_total_not_negative;
ALTER TABLE orders
    ADD CONSTRAINT orders_total_not_negative CHECK (total_amount >= 0);

-- every order belongs to a real customer. 210 old orders don't, and stay flagged.
ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_customer_fk;
ALTER TABLE orders
    ADD CONSTRAINT orders_customer_fk
    FOREIGN KEY (customer_id) REFERENCES customers (customer_id) NOT VALID;

-- order lines belong to a real order and a real product, with a sensible quantity and price.
ALTER TABLE order_items DROP CONSTRAINT IF EXISTS order_items_order_fk;
ALTER TABLE order_items
    ADD CONSTRAINT order_items_order_fk
    FOREIGN KEY (order_id) REFERENCES orders (order_id);

ALTER TABLE order_items DROP CONSTRAINT IF EXISTS order_items_product_fk;
ALTER TABLE order_items
    ADD CONSTRAINT order_items_product_fk
    FOREIGN KEY (product_id) REFERENCES products (product_id);

ALTER TABLE order_items DROP CONSTRAINT IF EXISTS order_items_quantity_positive;
ALTER TABLE order_items
    ADD CONSTRAINT order_items_quantity_positive CHECK (quantity > 0);

-- the largest genuine line in the data is 10 units. 100 leaves plenty of room for bulk
-- buyers and still stops a 999 or 9999 slipping in. any old line that couldn't be fixed
-- stays listed in dq.chk_implausible_quantities.
ALTER TABLE order_items DROP CONSTRAINT IF EXISTS order_items_quantity_sensible;
ALTER TABLE order_items
    ADD CONSTRAINT order_items_quantity_sensible CHECK (quantity <= 100) NOT VALID;

-- a handful of old lines still have no price (the order total couldn't confirm one).
-- new lines must have one.
ALTER TABLE order_items DROP CONSTRAINT IF EXISTS order_items_price_present;
ALTER TABLE order_items
    ADD CONSTRAINT order_items_price_present
    CHECK (unit_price IS NOT NULL AND unit_price > 0) NOT VALID;

-- products point at a real category. no category at all is still allowed: some products
-- genuinely haven't been placed yet, and the race test creates products without one.
ALTER TABLE products DROP CONSTRAINT IF EXISTS products_category_fk;
ALTER TABLE products
    ADD CONSTRAINT products_category_fk
    FOREIGN KEY (category_id) REFERENCES categories (category_id);

ALTER TABLE products DROP CONSTRAINT IF EXISTS products_price_positive;
ALTER TABLE products
    ADD CONSTRAINT products_price_positive CHECK (price > 0);

ALTER TABLE products DROP CONSTRAINT IF EXISTS products_reorder_level_valid;
ALTER TABLE products
    ADD CONSTRAINT products_reorder_level_valid CHECK (reorder_level >= 0);

-- categories point at a real parent, and never at themselves.
ALTER TABLE categories DROP CONSTRAINT IF EXISTS categories_parent_fk;
ALTER TABLE categories
    ADD CONSTRAINT categories_parent_fk
    FOREIGN KEY (parent_id) REFERENCES categories (category_id);

ALTER TABLE categories DROP CONSTRAINT IF EXISTS categories_not_own_parent;
ALTER TABLE categories
    ADD CONSTRAINT categories_not_own_parent CHECK (parent_id <> category_id);

-- a constraint can't see a loop that goes through several categories, so a trigger
-- checks the whole chain whenever a parent is set or changed.
CREATE OR REPLACE FUNCTION categories_block_loops()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.parent_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        WITH RECURSIVE up AS (
            SELECT c.category_id, c.parent_id
            FROM categories c
            WHERE c.category_id = NEW.parent_id
            UNION ALL
            SELECT c.category_id, c.parent_id
            FROM up
            JOIN categories c ON c.category_id = up.parent_id
        ) CYCLE category_id SET is_cycle USING walked
        SELECT 1 FROM up WHERE up.category_id = NEW.category_id
    ) THEN
        RAISE EXCEPTION 'category % cannot sit under % because that would create a loop',
            NEW.category_id, NEW.parent_id;
    END IF;

    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS categories_block_loops ON categories;
CREATE TRIGGER categories_block_loops
    BEFORE INSERT OR UPDATE OF parent_id ON categories
    FOR EACH ROW
    EXECUTE FUNCTION categories_block_loops();

-- stock movements: a known reason, a non-zero change (stock takes excepted), a real product.
-- the race test removes its orders before their log rows, so the order link clears itself
-- rather than blocking the delete.
ALTER TABLE inventory_log DROP CONSTRAINT IF EXISTS inventory_log_reason_valid;
ALTER TABLE inventory_log
    ADD CONSTRAINT inventory_log_reason_valid
    CHECK (reason IN ('sale', 'restock', 'return', 'correction', 'damage', 'stock_take', 'opening_balance'));

ALTER TABLE inventory_log DROP CONSTRAINT IF EXISTS inventory_log_change_valid;
ALTER TABLE inventory_log
    ADD CONSTRAINT inventory_log_change_valid
    CHECK (change_qty <> 0 OR reason = 'stock_take');

ALTER TABLE inventory_log DROP CONSTRAINT IF EXISTS inventory_log_product_fk;
ALTER TABLE inventory_log
    ADD CONSTRAINT inventory_log_product_fk
    FOREIGN KEY (product_id) REFERENCES products (product_id) NOT VALID;

ALTER TABLE inventory_log DROP CONSTRAINT IF EXISTS inventory_log_order_fk;
ALTER TABLE inventory_log
    ADD CONSTRAINT inventory_log_order_fk
    FOREIGN KEY (order_id) REFERENCES orders (order_id) ON DELETE SET NULL;
