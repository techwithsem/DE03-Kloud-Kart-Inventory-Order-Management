-- 05_stock_movements.sql
-- the audit trail. two ways stock can change, and both leave a row in inventory_log:
--
--   1. through place_order (sales) or record_stock_movement (restocks, returns, damage,
--      corrections). these write a full log row themselves: reason, order, note, stock after.
--   2. any other way at all, such as someone running an update by hand. a trigger catches
--      it and logs it as an unexplained correction, so it can't happen silently.
--
-- the routines set a flag for the length of their own transaction so the trigger knows
-- the movement is already logged and doesn't write it twice.

CREATE OR REPLACE FUNCTION log_untracked_stock_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF coalesce(current_setting('kloudkart.movement_logged', true), '') = 'on' THEN
        RETURN NULL;
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.stock_quantity <> 0 THEN
            INSERT INTO inventory_log (product_id, change_qty, reason, note, stock_after)
            VALUES (NEW.product_id, NEW.stock_quantity, 'opening_balance',
                    'stock the product was created with', NEW.stock_quantity);
        END IF;
    ELSIF NEW.stock_quantity IS DISTINCT FROM OLD.stock_quantity THEN
        INSERT INTO inventory_log (product_id, change_qty, reason, note, stock_after)
        VALUES (NEW.product_id, NEW.stock_quantity - OLD.stock_quantity, 'correction',
                'changed directly, not through the stock routines', NEW.stock_quantity);
    END IF;

    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS products_log_stock_change ON products;
CREATE TRIGGER products_log_stock_change
    AFTER INSERT OR UPDATE OF stock_quantity ON products
    FOR EACH ROW
    EXECUTE FUNCTION log_untracked_stock_change();

-- the one way the team should change stock for anything other than a sale.
-- the change is applied with the same single conditional update place_order uses, so it
-- is safe to run while orders are coming in, and it refuses to take stock below zero.
CREATE OR REPLACE FUNCTION record_stock_movement(
    p_product_id  bigint,
    p_change_qty  integer,
    p_reason      text,
    p_note        text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_stock_after integer;
    v_applied     boolean;
BEGIN
    IF p_reason NOT IN ('restock', 'return', 'correction', 'damage', 'stock_take') THEN
        RAISE EXCEPTION 'reason must be restock, return, correction, damage or stock_take, not %', p_reason
            USING HINT = 'sales go through place_order';
    END IF;

    IF p_reason IN ('correction', 'damage') AND nullif(trim(p_note), '') IS NULL THEN
        RAISE EXCEPTION 'a % needs a note saying what happened', p_reason;
    END IF;

    PERFORM set_config('kloudkart.movement_logged', 'on', true);

    UPDATE products
    SET stock_quantity = stock_quantity + p_change_qty
    WHERE product_id = p_product_id
      AND stock_quantity + p_change_qty >= 0
    RETURNING stock_quantity INTO v_stock_after;

    -- save the result now: the perform below resets found.
    v_applied := FOUND;

    PERFORM set_config('kloudkart.movement_logged', 'off', true);

    IF NOT v_applied THEN
        IF NOT EXISTS (SELECT 1 FROM products WHERE product_id = p_product_id) THEN
            RAISE EXCEPTION 'product % does not exist', p_product_id;
        END IF;
        RAISE EXCEPTION 'product % would go below zero stock', p_product_id;
    END IF;

    INSERT INTO inventory_log (product_id, change_qty, reason, note, stock_after)
    VALUES (p_product_id, p_change_qty, p_reason, p_note, v_stock_after);

    RETURN v_stock_after;
END
$$;

-- the 14 products showing negative stock. they were oversold, so what's really on the
-- shelf is zero. each one is reset with a logged correction, so the trail shows exactly
-- when and why it changed. a physical count should confirm these.
SELECT record_stock_movement(
           product_id,
           -stock_quantity,
           'correction',
           'stock was below zero after overselling; reset to zero pending a physical count'
       ) AS new_stock
FROM products
WHERE stock_quantity < 0;

-- now nothing can take stock below zero, by any route.
ALTER TABLE products DROP CONSTRAINT IF EXISTS products_stock_not_negative;
ALTER TABLE products
    ADD CONSTRAINT products_stock_not_negative CHECK (stock_quantity >= 0);
