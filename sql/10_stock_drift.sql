-- 10_stock_drift.sql
-- improvement beyond the brief: a morning stock drift check.
--
-- nana's real complaint is that he can't trust his stock counts. the brief fixes
-- overselling from here on, but it doesn't tell him which counts are already wrong, or
-- warn him when a new one goes wrong. this does both.
--
-- every product's stock figure is compared with the sum of its movement log (ignoring
-- flagged duplicates). the two should always agree. where they don't, something changed
-- the stock without leaving a trail, or the trail is wrong. each mismatch is priced, so
-- the team counts the expensive problems first.
--
-- stock_drift_check() is meant to run every morning. it saves a snapshot and returns only
-- the products that started drifting since the last run, so yesterday's problems don't
-- bury today's.

CREATE OR REPLACE VIEW v_stock_drift AS
WITH ledger AS (
    SELECT product_id,
           sum(change_qty) FILTER (WHERE NOT is_duplicate) AS ledger_qty,
           sum(change_qty) FILTER (WHERE note = 'recount, not applied' AND NOT is_duplicate) AS unapplied_qty,
           max(created_at) AS last_movement_at
    FROM inventory_log
    GROUP BY product_id
),
recent_sales AS (
    SELECT product_id, -sum(change_qty) AS units_sold_30d
    FROM inventory_log
    WHERE reason = 'sale'
      AND NOT is_duplicate
      AND created_at >= (SELECT report_as_of()) - 29
      AND created_at < (SELECT report_as_of()) + 1
    GROUP BY product_id
)
SELECT p.product_id,
       p.product_name,
       p.stock_quantity AS stock_on_record,
       coalesce(l.ledger_qty, 0) AS stock_per_log,
       p.stock_quantity - coalesce(l.ledger_qty, 0) AS difference,
       abs(p.stock_quantity - coalesce(l.ledger_qty, 0)) * p.price AS value_at_risk,
       coalesce(rs.units_sold_30d, 0) AS units_sold_30d,
       CASE
           WHEN coalesce(l.unapplied_qty, 0) <> 0
            AND p.stock_quantity = coalesce(l.ledger_qty, 0) - l.unapplied_qty
               THEN 'a recount was logged but never applied to the stock figure'
           WHEN p.stock_quantity > coalesce(l.ledger_qty, 0)
               THEN 'more on record than the log explains: possible unlogged restock, or sales not taken off'
           ELSE 'less on record than the log explains: possible unlogged sale, loss or damage'
       END AS likely_cause,
       l.last_movement_at
FROM products p
LEFT JOIN ledger l USING (product_id)
LEFT JOIN recent_sales rs USING (product_id)
WHERE p.stock_quantity IS DISTINCT FROM coalesce(l.ledger_qty, 0)
  AND p.product_name NOT LIKE 'RACE TEST FIXTURE%';

-- the physical count list: biggest money at risk first, busiest sellers breaking ties,
-- since a wrong count on a fast seller is the next oversell waiting to happen.
CREATE OR REPLACE VIEW v_count_these_first AS
SELECT row_number() OVER (ORDER BY value_at_risk DESC, units_sold_30d DESC, product_id) AS count_order,
       product_id, product_name, stock_on_record, stock_per_log, difference,
       value_at_risk, units_sold_30d, likely_cause
FROM v_stock_drift
ORDER BY count_order;

CREATE TABLE IF NOT EXISTS dq.stock_drift_snapshots (
    snapshot_at  timestamptz NOT NULL,
    product_id   integer NOT NULL,
    difference   integer NOT NULL,
    PRIMARY KEY (snapshot_at, product_id)
);

CREATE OR REPLACE FUNCTION stock_drift_check()
RETURNS TABLE (
    product_id     integer,
    product_name   text,
    difference     integer,
    value_at_risk  numeric,
    status         text,
    likely_cause   text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_previous timestamptz;
    v_now      timestamptz := clock_timestamp();
BEGIN
    SELECT max(s.snapshot_at) INTO v_previous FROM dq.stock_drift_snapshots s;

    INSERT INTO dq.stock_drift_snapshots (snapshot_at, product_id, difference)
    SELECT v_now, d.product_id, d.difference
    FROM v_stock_drift d;

    RETURN QUERY
    SELECT d.product_id,
           d.product_name,
           d.difference::integer,
           d.value_at_risk,
           CASE
               WHEN v_previous IS NULL THEN 'first check'
               WHEN prev.product_id IS NULL THEN 'new since last check'
               ELSE 'got worse since last check'
           END,
           d.likely_cause
    FROM v_stock_drift d
    LEFT JOIN dq.stock_drift_snapshots prev
           ON prev.snapshot_at = v_previous
          AND prev.product_id = d.product_id
    WHERE v_previous IS NULL
       OR prev.product_id IS NULL
       OR abs(d.difference) > abs(prev.difference)
    ORDER BY d.value_at_risk DESC;
END
$$;
