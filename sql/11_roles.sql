-- 11_roles.sql
-- who can do what. the shop's application should never update stock directly, and nobody
-- should be able to edit or delete the audit trail. these roles make that the default.
--
-- they are created without a login. the team creates real logins and grants a role, e.g.
--   create role checkout_service login password '...' in role kk_app;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kk_app') THEN
        CREATE ROLE kk_app NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kk_stock') THEN
        CREATE ROLE kk_stock NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kk_analyst') THEN
        CREATE ROLE kk_analyst NOLOGIN;
    END IF;
END
$$;

-- functions are executable by everyone by default in postgres. close that first.
REVOKE ALL ON FUNCTION place_order(bigint, bigint, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_stock_movement(bigint, integer, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION refresh_monday_report() FROM PUBLIC;
REVOKE ALL ON FUNCTION stock_drift_check() FROM PUBLIC;

-- the checkout application: read the catalogue, place orders. it cannot touch stock or
-- the log except through place_order, which runs with the owner's rights.
GRANT USAGE ON SCHEMA public TO kk_app;
GRANT SELECT ON products, categories, customers TO kk_app;
GRANT SELECT ON orders, order_items TO kk_app;
GRANT EXECUTE ON FUNCTION place_order(bigint, bigint, integer) TO kk_app;

-- the warehouse team: restocks, returns, damage, corrections, always through the routine
-- that logs them. they can read the trail but not change it.
GRANT USAGE ON SCHEMA public TO kk_stock;
GRANT SELECT ON products, categories, inventory_log TO kk_stock;
GRANT SELECT ON v_low_stock_by_category, v_low_stock_products, v_stock_drift, v_count_these_first TO kk_stock;
GRANT EXECUTE ON FUNCTION record_stock_movement(bigint, integer, text, text) TO kk_stock;
GRANT EXECUTE ON FUNCTION stock_drift_check() TO kk_stock;
GRANT USAGE ON SCHEMA dq TO kk_stock;
GRANT SELECT ON dq.stock_drift_snapshots TO kk_stock;

-- adwoa and anyone reporting: read everything, change nothing, and refresh the report.
GRANT USAGE ON SCHEMA public, dq TO kk_analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO kk_analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA dq TO kk_analyst;
GRANT EXECUTE ON FUNCTION refresh_monday_report() TO kk_analyst;

-- nobody but the owner may rewrite history.
REVOKE UPDATE, DELETE, TRUNCATE ON inventory_log FROM PUBLIC, kk_app, kk_stock, kk_analyst;
