-- 08_monday_report.sql
-- needs: 03 (clean data) and 07 (the indexes the refresh relies on).
-- adwoa's monday customer-spending report.
--
-- what counts as spend: the order's lines (quantity x price paid), for orders that are
-- completed or shipped. pending orders aren't paid yet; cancelled and refunded orders gave
-- the money back. the order header total isn't used because on about 1,600 orders it
-- disagrees with the lines by a fixed percentage, which points to a checkout bug.
--
-- an order with a line of more than 100 units is left out entirely. five such lines were
-- corrected from their order totals in 03. the one that couldn't be is on a cancelled
-- order, so it wouldn't count anyway, but a line like that is worth ₵1.1m and the guard
-- stops the next one landing in a customer's total.
--
-- the period: the twelve calendar months ending with the month of report_as_of(). orders
-- dated after that day are left out (24 of them carry dates in the future).
--
-- report_as_of() is always called as (select report_as_of()) or from a materialized cte,
-- so it runs once per query. called bare in a where or filter it would run once per row,
-- which cost about 10 seconds per refresh before this was spotted.
--
-- why it's fast: the old report recalculated each figure customer by customer, reading the
-- whole order history again every time. here the orders are read once, totalled once per
-- customer per month, and everything else (12-month columns, running totals, ranking) is
-- worked out from that much smaller set. the result is stored, so opening the report on
-- monday is reading a ready table. refresh_monday_report() rebuilds it.

-- one row per order that counts as spend, with its value worked out from its lines.
CREATE OR REPLACE VIEW v_order_spend AS
SELECT o.order_id,
       o.customer_id,
       o.order_date,
       date_trunc('month', o.order_date)::date AS order_month,
       sum(oi.quantity * oi.unit_price) AS order_value
FROM orders o
JOIN order_items oi USING (order_id)
WHERE o.status IN ('completed', 'shipped')
  AND o.order_date < (SELECT report_as_of()) + 1
  AND NOT EXISTS (
      SELECT 1
      FROM order_items bad
      WHERE bad.order_id = o.order_id
        AND bad.quantity > 100
  )
GROUP BY o.order_id, o.customer_id, o.order_date;

-- per customer, per month: spend, orders, and the running total to date.
DROP MATERIALIZED VIEW IF EXISTS mv_customer_spend_report CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_customer_monthly_spend CASCADE;

CREATE MATERIALIZED VIEW mv_customer_monthly_spend AS
SELECT s.customer_id,
       s.order_month,
       count(*) AS orders,
       sum(s.order_value) AS spend,
       sum(sum(s.order_value)) OVER (
           PARTITION BY s.customer_id
           ORDER BY s.order_month
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS running_total
FROM v_order_spend s
JOIN customers c USING (customer_id)
GROUP BY s.customer_id, s.order_month;

CREATE UNIQUE INDEX mv_customer_monthly_spend_key
    ON mv_customer_monthly_spend (customer_id, order_month);

-- the report itself: one row for every customer, including those who spent nothing.
-- spend_m01 is the oldest of the twelve months and spend_m12 the latest; v_report_months
-- gives the calendar month behind each column.
--
-- ranking: by lifetime spend, highest first. ties share a rank (1, 2, 2, 4), so the
-- top 100 can hold a few more than 100 people if several tie at 100th.
CREATE MATERIALIZED VIEW mv_customer_spend_report AS
WITH bounds AS MATERIALIZED (
    SELECT report_as_of() AS as_of_date,
           (date_trunc('month', report_as_of()) - interval '11 months')::date AS first_month
),
per_customer AS (
    SELECT m.customer_id,
           sum(m.spend) AS total_spent,
           sum(m.orders) AS order_count,
           max(m.order_month) AS last_order_month,
           sum(m.spend) FILTER (WHERE m.order_month >= b.first_month) AS spend_12m,
           sum(m.spend) FILTER (WHERE m.order_month = b.first_month) AS spend_m01,
           sum(m.spend) FILTER (WHERE m.order_month = (b.first_month + interval '1 month')::date) AS spend_m02,
           sum(m.spend) FILTER (WHERE m.order_month = (b.first_month + interval '2 months')::date) AS spend_m03,
           sum(m.spend) FILTER (WHERE m.order_month = (b.first_month + interval '3 months')::date) AS spend_m04,
           sum(m.spend) FILTER (WHERE m.order_month = (b.first_month + interval '4 months')::date) AS spend_m05,
           sum(m.spend) FILTER (WHERE m.order_month = (b.first_month + interval '5 months')::date) AS spend_m06,
           sum(m.spend) FILTER (WHERE m.order_month = (b.first_month + interval '6 months')::date) AS spend_m07,
           sum(m.spend) FILTER (WHERE m.order_month = (b.first_month + interval '7 months')::date) AS spend_m08,
           sum(m.spend) FILTER (WHERE m.order_month = (b.first_month + interval '8 months')::date) AS spend_m09,
           sum(m.spend) FILTER (WHERE m.order_month = (b.first_month + interval '9 months')::date) AS spend_m10,
           sum(m.spend) FILTER (WHERE m.order_month = (b.first_month + interval '10 months')::date) AS spend_m11,
           sum(m.spend) FILTER (WHERE m.order_month = (b.first_month + interval '11 months')::date) AS spend_m12
    FROM mv_customer_monthly_spend m
    CROSS JOIN bounds b
    GROUP BY m.customer_id
)
SELECT c.customer_id,
       trim(c.full_name) AS full_name,
       lower(trim(c.email)) AS email,
       initcap(trim(c.city)) AS city,
       coalesce(p.total_spent, 0) AS total_spent,
       coalesce(p.order_count, 0) AS order_count,
       p.last_order_month,
       coalesce(p.spend_12m, 0) AS spend_12m,
       coalesce(p.spend_m01, 0) AS spend_m01,
       coalesce(p.spend_m02, 0) AS spend_m02,
       coalesce(p.spend_m03, 0) AS spend_m03,
       coalesce(p.spend_m04, 0) AS spend_m04,
       coalesce(p.spend_m05, 0) AS spend_m05,
       coalesce(p.spend_m06, 0) AS spend_m06,
       coalesce(p.spend_m07, 0) AS spend_m07,
       coalesce(p.spend_m08, 0) AS spend_m08,
       coalesce(p.spend_m09, 0) AS spend_m09,
       coalesce(p.spend_m10, 0) AS spend_m10,
       coalesce(p.spend_m11, 0) AS spend_m11,
       coalesce(p.spend_m12, 0) AS spend_m12,
       rank() OVER (ORDER BY coalesce(p.total_spent, 0) DESC) AS spend_rank,
       b.as_of_date
FROM customers c
CROSS JOIN bounds b
LEFT JOIN per_customer p USING (customer_id);

CREATE UNIQUE INDEX mv_customer_spend_report_key
    ON mv_customer_spend_report (customer_id);

CREATE INDEX mv_customer_spend_report_rank
    ON mv_customer_spend_report (spend_rank);

-- the calendar month behind each spend_mnn column.
CREATE OR REPLACE VIEW v_report_months AS
SELECT format('spend_m%s', lpad(n::text, 2, '0')) AS report_column,
       (date_trunc('month', report_as_of()) - make_interval(months => 12 - n))::date AS month_start,
       to_char(date_trunc('month', report_as_of()) - make_interval(months => 12 - n), 'Mon YYYY') AS month_label
FROM generate_series(1, 12) AS n;

-- the top 100, as adwoa would want to read it.
CREATE OR REPLACE VIEW v_top_100_customers AS
SELECT spend_rank, customer_id, full_name, email, city,
       total_spent, order_count, spend_12m, last_order_month
FROM mv_customer_spend_report
WHERE spend_rank <= 100
ORDER BY spend_rank, customer_id;

-- rebuild both summaries. concurrently means the old figures stay readable while the new
-- ones are worked out, so nobody gets a blank report mid-refresh.
CREATE OR REPLACE FUNCTION refresh_monday_report()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_started timestamptz := clock_timestamp();
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_customer_monthly_spend;
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_customer_spend_report;
    RETURN format('monday report rebuilt in %s ms, as of %s',
                  round(extract(epoch FROM clock_timestamp() - v_started) * 1000),
                  report_as_of());
END
$$;
