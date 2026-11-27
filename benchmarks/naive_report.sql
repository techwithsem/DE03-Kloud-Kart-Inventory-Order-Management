-- naive_report.sql
-- the "before" version of the monday report, written the way it usually starts out: one
-- row per customer, and every figure worked out by its own subquery that goes back to the
-- full order history for that one customer.
--
-- it produces the same figures as mv_customer_spend_report, so the timings compare like
-- with like. run it against a fresh load (no indexes) to get the "before" number.
--
-- usage:
--   psql -v customer_limit=200 -f benchmarks/naive_report.sql
-- customer_limit keeps the run short enough to measure; the full figure is scaled up
-- from it in docs/measurement_report.md.

\if :{?customer_limit}
\else
\set customer_limit 40420
\endif

EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, SUMMARY ON)
WITH some_customers AS (
    SELECT *
    FROM customers
    ORDER BY customer_id
    LIMIT :customer_limit
),
report AS (
    SELECT c.customer_id,
           c.full_name,
           (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
              FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date < DATE '2026-09-01') AS total_spent,
           (SELECT count(*)
              FROM orders o
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date < DATE '2026-09-01') AS order_count,
           (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
              FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date >= DATE '2025-09-01' AND o.order_date < DATE '2025-10-01') AS spend_m01,
           (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
              FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date >= DATE '2025-10-01' AND o.order_date < DATE '2025-11-01') AS spend_m02,
           (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
              FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date >= DATE '2025-11-01' AND o.order_date < DATE '2025-12-01') AS spend_m03,
           (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
              FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date >= DATE '2025-12-01' AND o.order_date < DATE '2026-01-01') AS spend_m04,
           (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
              FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date >= DATE '2026-01-01' AND o.order_date < DATE '2026-02-01') AS spend_m05,
           (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
              FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date >= DATE '2026-02-01' AND o.order_date < DATE '2026-03-01') AS spend_m06,
           (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
              FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date >= DATE '2026-03-01' AND o.order_date < DATE '2026-04-01') AS spend_m07,
           (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
              FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date >= DATE '2026-04-01' AND o.order_date < DATE '2026-05-01') AS spend_m08,
           (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
              FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date >= DATE '2026-05-01' AND o.order_date < DATE '2026-06-01') AS spend_m09,
           (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
              FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date >= DATE '2026-06-01' AND o.order_date < DATE '2026-07-01') AS spend_m10,
           (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
              FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date >= DATE '2026-07-01' AND o.order_date < DATE '2026-08-01') AS spend_m11,
           (SELECT coalesce(sum(oi.quantity * oi.unit_price), 0)
              FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
             WHERE o.customer_id = c.customer_id
               AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
               AND o.order_date >= DATE '2026-08-01' AND o.order_date < DATE '2026-09-01') AS spend_m12
    FROM some_customers c
)
SELECT r.*,
       (SELECT count(*) + 1 FROM report r2 WHERE r2.total_spent > r.total_spent) AS spend_rank
FROM report r
ORDER BY spend_rank;
