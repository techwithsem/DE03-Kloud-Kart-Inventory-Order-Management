-- after_queries.sql
-- the "after" measurements, run against a database built by sql/run_all.sql.

\timing on
\pset footer off

\echo '-- a. single-pass report query, computed from scratch (what a refresh does)'
EXPLAIN (ANALYZE, BUFFERS, SUMMARY ON)
SELECT customer_id, order_month, count(*), sum(order_value)
FROM v_order_spend
JOIN customers USING (customer_id)
GROUP BY customer_id, order_month;

\echo '-- b. full rebuild of both report summaries, three runs'
SELECT refresh_monday_report();
SELECT refresh_monday_report();
SELECT refresh_monday_report();

\echo '-- c. reading the finished report: every customer, ranked'
EXPLAIN (ANALYZE, SUMMARY ON)
SELECT * FROM mv_customer_spend_report ORDER BY spend_rank;

\echo '-- d. the top 100'
EXPLAIN (ANALYZE, SUMMARY ON)
SELECT * FROM v_top_100_customers;

\echo '-- e. category low-stock rollup, live (no stored summary)'
EXPLAIN (ANALYZE, BUFFERS, SUMMARY ON)
SELECT * FROM v_low_stock_by_category ORDER BY category;

\echo '-- f. the morning stock drift check'
EXPLAIN (ANALYZE, SUMMARY ON)
SELECT * FROM v_count_these_first;
