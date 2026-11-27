-- 12_self_checks.sql
-- checks that the main outputs are actually right, run at the end of every build.
-- each check works the answer out a second, independent way and stops the build with a
-- clear message if the two disagree. nothing here changes data: the order test runs
-- inside a block that is always rolled back.

DO $$
DECLARE
    v_customers        bigint;
    v_report_rows      bigint;
    v_report_distinct  bigint;
    v_report_total     numeric;
    v_direct_total     numeric;
    v_bad_running      bigint;
    v_bad_12m          bigint;
    v_top_spend        numeric;
    v_max_spend        numeric;
BEGIN
    -- one report row per customer, no more, no fewer.
    SELECT count(*) INTO v_customers FROM customers;
    SELECT count(*), count(DISTINCT customer_id)
      INTO v_report_rows, v_report_distinct
      FROM mv_customer_spend_report;

    IF v_report_rows <> v_customers OR v_report_distinct <> v_customers THEN
        RAISE EXCEPTION 'self check failed: report has % rows (% distinct) for % customers',
            v_report_rows, v_report_distinct, v_customers;
    END IF;

    -- total spend in the report against the same rules applied straight to the raw tables,
    -- without going through any of the report's own views.
    SELECT sum(total_spent) INTO v_report_total FROM mv_customer_spend_report;

    SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
      INTO v_direct_total
      FROM orders o
      JOIN customers c ON c.customer_id = o.customer_id
      JOIN order_items oi ON oi.order_id = o.order_id
     WHERE o.status IN ('completed', 'shipped')
       AND o.order_date < (SELECT report_as_of()) + 1
       AND o.order_id NOT IN (SELECT order_id FROM order_items WHERE quantity > 100);

    IF abs(v_report_total - v_direct_total) > 0.01 THEN
        RAISE EXCEPTION 'self check failed: report total % does not match the raw tables %',
            v_report_total, v_direct_total;
    END IF;

    -- each customer's running total must end at their lifetime total.
    SELECT count(*) INTO v_bad_running
      FROM mv_customer_spend_report r
      JOIN (
          SELECT customer_id, max(running_total) AS final_running_total
          FROM mv_customer_monthly_spend
          GROUP BY customer_id
      ) m USING (customer_id)
     WHERE abs(r.total_spent - m.final_running_total) > 0.01;

    IF v_bad_running > 0 THEN
        RAISE EXCEPTION 'self check failed: % customers have a running total that does not end at their total', v_bad_running;
    END IF;

    -- the twelve monthly columns must add up to the twelve-month figure.
    SELECT count(*) INTO v_bad_12m
      FROM mv_customer_spend_report
     WHERE abs(spend_12m - (spend_m01 + spend_m02 + spend_m03 + spend_m04 + spend_m05 + spend_m06
                          + spend_m07 + spend_m08 + spend_m09 + spend_m10 + spend_m11 + spend_m12)) > 0.01;

    IF v_bad_12m > 0 THEN
        RAISE EXCEPTION 'self check failed: % customers have monthly figures that do not add up to their 12-month total', v_bad_12m;
    END IF;

    -- rank 1 must be the biggest spender.
    SELECT max(total_spent) INTO v_max_spend FROM mv_customer_spend_report;
    SELECT max(total_spent) INTO v_top_spend FROM mv_customer_spend_report WHERE spend_rank = 1;

    IF v_top_spend IS DISTINCT FROM v_max_spend THEN
        RAISE EXCEPTION 'self check failed: rank 1 spent %, but the biggest spender spent %', v_top_spend, v_max_spend;
    END IF;
END
$$;

DO $$
DECLARE
    v_products          bigint;
    v_rolled_top_level  bigint;
    v_bad_parents       bigint;
BEGIN
    -- no double counting in the category rollup: the top-level categories plus
    -- "uncategorised" must hold every product exactly once between them.
    SELECT count(*) INTO v_products
      FROM products
     WHERE product_name NOT LIKE 'RACE TEST FIXTURE%';

    SELECT sum(products) INTO v_rolled_top_level
      FROM v_low_stock_by_category
     WHERE depth = 1;

    IF v_rolled_top_level <> v_products THEN
        RAISE EXCEPTION 'self check failed: the top of the category rollup holds % products, there are %',
            v_rolled_top_level, v_products;
    END IF;

    -- a parent can never show fewer products than any one of its children.
    SELECT count(*) INTO v_bad_parents
      FROM v_low_stock_by_category child
      JOIN categories c ON c.category_id = child.category_id
      JOIN v_low_stock_by_category parent ON parent.category_id = c.parent_id
     WHERE parent.products < child.products;

    IF v_bad_parents > 0 THEN
        RAISE EXCEPTION 'self check failed: % categories show more products than their parent', v_bad_parents;
    END IF;
END
$$;

DO $$
DECLARE
    v_customer_id  bigint;
    v_product_id   bigint;
    v_first        record;
    v_second       record;
    v_too_many     record;
    v_stock_after  integer;
    v_log_rows     bigint;
BEGIN
    -- place_order end to end, on a throwaway product, then everything is rolled back.
    BEGIN
        SELECT min(customer_id) INTO v_customer_id FROM customers;
        SELECT coalesce(max(product_id), 0) + 900000 INTO v_product_id FROM products;

        INSERT INTO products (product_id, product_name, category_id, price, stock_quantity, created_at)
        VALUES (v_product_id, 'RACE TEST FIXTURE self check', NULL, 10.00, 1, now());

        SELECT * INTO v_first FROM place_order(v_customer_id, v_product_id, 1);
        SELECT * INTO v_second FROM place_order(v_customer_id, v_product_id, 1);
        SELECT stock_quantity INTO v_stock_after FROM products WHERE product_id = v_product_id;
        SELECT count(*) INTO v_log_rows
          FROM inventory_log
         WHERE product_id = v_product_id AND reason = 'sale' AND order_id = v_first.order_id;

        UPDATE products SET stock_quantity = 2 WHERE product_id = v_product_id;
        SELECT * INTO v_too_many FROM place_order(v_customer_id, v_product_id, 5);

        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'self check rollback';
    EXCEPTION
        WHEN raise_exception THEN
            IF SQLERRM <> 'self check rollback' THEN
                RAISE;
            END IF;
    END;

    IF NOT v_first.success OR v_first.order_id IS NULL THEN
        RAISE EXCEPTION 'self check failed: the first order for the last unit was refused: %', v_first.message;
    END IF;
    IF v_second.success OR position('out of stock' IN lower(v_second.message)) = 0 THEN
        RAISE EXCEPTION 'self check failed: the second order for the last unit was not refused as out of stock: %', v_second.message;
    END IF;
    IF v_stock_after <> 0 THEN
        RAISE EXCEPTION 'self check failed: stock ended at %, expected 0', v_stock_after;
    END IF;
    IF v_log_rows <> 1 THEN
        RAISE EXCEPTION 'self check failed: the sale left % log rows tied to its order, expected 1', v_log_rows;
    END IF;
    IF v_too_many.success OR position('out of stock' IN lower(v_too_many.message)) = 0 THEN
        RAISE EXCEPTION 'self check failed: an order for 5 against 2 in stock was not refused: %', v_too_many.message;
    END IF;
END
$$;

SELECT 'self checks passed' AS result;
