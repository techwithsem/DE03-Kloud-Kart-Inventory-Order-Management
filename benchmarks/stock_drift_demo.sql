-- stock_drift_demo.sql
-- shows the audit trail and the morning drift check working. everything runs inside a
-- transaction that is rolled back at the end, so the database is left as it was.

\pset footer off
BEGIN;

\echo '-- 1. the first morning check: every product already drifting'
SELECT status, count(*) AS products, round(sum(value_at_risk)) AS value_at_risk_ghs
FROM stock_drift_check()
GROUP BY status;

\echo '-- 2. someone changes stock by hand, bypassing the routines'
UPDATE products SET stock_quantity = stock_quantity + 5 WHERE product_id = 5001;

\echo '-- the trigger logged it anyway'
SELECT product_id, change_qty, reason, note, stock_after, recorded_by
FROM inventory_log
WHERE product_id = 5001
ORDER BY log_id DESC
LIMIT 1;

\echo '-- 3. a movement gets written to the log but never applied to stock'
\echo '--    (the "recount, not applied" pattern found in the data)'
INSERT INTO inventory_log (product_id, change_qty, reason, note)
VALUES (5002, -3, 'correction', 'recount, not applied');

\echo '-- 4. the next morning check reports only what is new'
SELECT product_id, product_name, difference, round(value_at_risk) AS value_at_risk_ghs, status, likely_cause
FROM stock_drift_check();

\echo '-- 5. restocking through the proper routine: logged, with stock after'
SELECT record_stock_movement(5003, 12, 'restock', 'supplier delivery') AS stock_after;
SELECT product_id, change_qty, reason, note, stock_after
FROM inventory_log
WHERE product_id = 5003
ORDER BY log_id DESC
LIMIT 1;

\echo '-- 6. a correction without a note is refused'
SAVEPOINT before_bad;
SELECT record_stock_movement(5003, -1, 'correction', NULL);
ROLLBACK TO before_bad;

\echo '-- 7. and stock can never go below zero, by any route'
SAVEPOINT before_negative;
UPDATE products SET stock_quantity = -1 WHERE product_id = 5003;
ROLLBACK TO before_negative;

ROLLBACK;
