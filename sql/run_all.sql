-- kloud kart: full solution, run top to bottom against a fresh load.
--
-- load the supplied schema and data first, then run this file from the repository root.
-- the exact commands are in readme.md, or scripts/reset_and_run.ps1 does all of it.
--
-- every file is safe to run more than once.

\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;

\echo '== 00 preflight'
\ir 00_preflight.sql
\echo '== 01 diagnosis (baseline counts saved before anything changes)'
\ir 01_diagnosis.sql
\echo '== 02 schema changes'
\ir 02_schema_changes.sql
\echo '== 03 data cleanup'
\ir 03_cleanup.sql
\echo '== 04 constraints'
\ir 04_constraints.sql
\echo '== 05 stock movements and audit trail'
\ir 05_stock_movements.sql
\echo '== 06 place_order'
\ir 06_place_order.sql
\echo '== 07 indexes'
\ir 07_indexes.sql
\echo '== 08 monday report'
\ir 08_monday_report.sql
\echo '== 09 category low-stock rollup'
\ir 09_category_rollup.sql
\echo '== 10 improvement: stock drift check'
\ir 10_stock_drift.sql
\echo '== 11 roles and permissions'
\ir 11_roles.sql

ANALYZE;

\echo '== done. data quality before and after:'
SELECT finding, rows_before, rows_now
FROM dq.findings_before_after
ORDER BY danger_rank;
