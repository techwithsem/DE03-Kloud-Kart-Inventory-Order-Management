-- 00_preflight.sql
-- needs: the supplied schema.sql and load.sql, loaded into an empty database.
-- check the server can actually run this solution and its test before we touch anything.

DO $$
BEGIN
    -- the race test opens 400 connections at once. on a default install (100) it fails
    -- with errors that never mention connections, so catch it here instead.
    IF current_setting('max_connections')::int < 500 THEN
        RAISE EXCEPTION 'max_connections is %, the race test needs at least 500. restart postgres with -c max_connections=500',
            current_setting('max_connections');
    END IF;

    -- the category rollup uses the cycle clause, which arrived in postgresql 14.
    IF current_setting('server_version_num')::int < 140000 THEN
        RAISE EXCEPTION 'postgresql 14 or newer is required, this server is %', current_setting('server_version');
    END IF;
END
$$;

-- everything to do with data quality (checks, quarantined rows, the before/after record)
-- lives in its own schema so it never gets mixed up with the tables the shop runs on.
CREATE SCHEMA IF NOT EXISTS dq;

-- one row of settings shared by the diagnosis and the monday report.
-- as_of_date is the day the reports treat as "today". the extract we were given stops on
-- 2026-08-31, so that is what it is set to here. on the live server set it to null and
-- the reports will use the real current date.
CREATE TABLE IF NOT EXISTS report_settings (
    singleton   boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    as_of_date  date
);

INSERT INTO report_settings (as_of_date)
VALUES (DATE '2026-08-31')
ON CONFLICT (singleton) DO NOTHING;

-- postgres 17 and later build materialized views with a locked-down search path, so this
-- function names its schema explicitly.
CREATE OR REPLACE FUNCTION report_as_of()
RETURNS date
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT coalesce((SELECT as_of_date FROM public.report_settings), current_date);
$$;

-- race_test.py creates its own products, named 'RACE TEST FIXTURE ...', and deletes them
-- when it finishes. it can't be edited and marks them no other way, so the name is the only
-- way to tell them apart. every view that counts products leaves them out through this one
-- function, so the rule lives in one place.
CREATE OR REPLACE FUNCTION is_test_fixture(p_product_name text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT p_product_name LIKE 'RACE TEST FIXTURE%';
$$;
