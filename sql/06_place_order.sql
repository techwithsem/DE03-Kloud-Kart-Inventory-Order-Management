-- 06_place_order.sql
-- placing an order without ever selling stock that isn't there.
--
-- how it works: the stock check and the stock decrement are one statement.
--
--     update products set stock_quantity = stock_quantity - qty
--     where product_id = ? and stock_quantity >= qty
--
-- two buyers racing for the last unit both reach that update. postgres lets the first one
-- lock the row; the second waits. when the first commits, postgres re-checks the second
-- buyer's where clause against the new stock (now 0), finds no match, and the second buyer gets
-- "out of stock". no window between checking and taking, nothing to retry, no
-- serialization errors. under a flash sale, 400 buyers simply queue on that one row for a
-- few milliseconds each.
--
-- the order, its line and its stock movement are written in the same transaction as the
-- decrement, so you can't get one without the others.

CREATE OR REPLACE FUNCTION place_order(
    p_customer_id  bigint,
    p_product_id   bigint,
    p_quantity     integer
)
RETURNS TABLE (success boolean, order_id bigint, message text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
SET lock_timeout = '5s'
AS $$
#variable_conflict use_column
DECLARE
    v_price        numeric(12,2);
    v_stock_after  integer;
    v_available    integer;
    v_order_id     bigint;
    v_took_stock   boolean;
    v_now          timestamp := now() AT TIME ZONE 'Africa/Accra';
BEGIN
    IF p_quantity IS NULL OR p_quantity < 1 THEN
        RETURN QUERY SELECT false, NULL::bigint, 'quantity must be at least 1'::text;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = p_customer_id) THEN
        RETURN QUERY SELECT false, NULL::bigint, format('customer %s does not exist', p_customer_id);
        RETURN;
    END IF;

    BEGIN
        -- tell the stock trigger this movement is logged below, so it isn't logged twice.
        PERFORM set_config('kloudkart.movement_logged', 'on', true);

        UPDATE products p
        SET stock_quantity = p.stock_quantity - p_quantity
        WHERE p.product_id = p_product_id
          AND p.stock_quantity >= p_quantity
        RETURNING p.price, p.stock_quantity INTO v_price, v_stock_after;

        -- save the result now: the perform below resets found.
        v_took_stock := FOUND;

        PERFORM set_config('kloudkart.movement_logged', 'off', true);

        IF NOT v_took_stock THEN
            SELECT p.stock_quantity INTO v_available
            FROM products p
            WHERE p.product_id = p_product_id;

            IF NOT FOUND THEN
                RETURN QUERY SELECT false, NULL::bigint, format('product %s does not exist', p_product_id);
            ELSIF v_available = 0 THEN
                RETURN QUERY SELECT false, NULL::bigint, 'Sorry, this item is out of stock.'::text;
            ELSE
                RETURN QUERY SELECT false, NULL::bigint,
                    format('Out of stock: you asked for %s but only %s left.', p_quantity, v_available);
            END IF;
            RETURN;
        END IF;

        INSERT INTO orders AS o (customer_id, order_date, status, total_amount)
        VALUES (p_customer_id, v_now, 'pending', v_price * p_quantity)
        RETURNING o.order_id INTO v_order_id;

        INSERT INTO order_items (order_id, product_id, quantity, unit_price)
        VALUES (v_order_id, p_product_id, p_quantity, v_price);

        INSERT INTO inventory_log (product_id, change_qty, reason, created_at, note, order_id, stock_after)
        VALUES (p_product_id, -p_quantity, 'sale', v_now, NULL, v_order_id, v_stock_after);

        RETURN QUERY SELECT true, v_order_id, format('order %s placed', v_order_id);

    EXCEPTION
        -- if the row is held for longer than lock_timeout, or postgres ever picks this
        -- call as a deadlock victim, the customer gets a clear answer instead of an error.
        -- everything inside this block is rolled back, so no stock is taken.
        WHEN lock_not_available OR deadlock_detected OR serialization_failure THEN
            RETURN QUERY SELECT false, NULL::bigint,
                'we are very busy right now and could not confirm stock, please try again'::text;
    END;
END
$$;

COMMENT ON FUNCTION place_order(bigint, bigint, integer) IS
    'places a one-line order. never oversells: the stock check and decrement are one statement. '
    'returns success=false with "out of stock" in the message when there is not enough.';
