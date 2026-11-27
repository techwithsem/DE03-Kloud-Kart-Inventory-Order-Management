# DE03-Kloud-Kart-Inventory-Order-Management

Kloud Kart sells around 4,000 orders a day from a single PostgreSQL server. Two things were hurting the business: the same last unit was occasionally sold to two customers, and the Monday customer-spending report took about 40 minutes, when it finished at all. This repository fixes both, rolls low stock up through the category tree, leaves a stock trail an auditor can follow, and documents what's wrong with the data.

Everything runs on plain PostgreSQL. No new services, no new bills.

## What's where

| Deliverable | Where |
|---|---|
| 1. Data diagnosis | [docs/data_diagnosis.md](docs/data_diagnosis.md), checks in [sql/01_diagnosis.sql](sql/01_diagnosis.sql) |
| 2. Working SQL solution | [sql/](sql/), run in order by [sql/run_all.sql](sql/run_all.sql) |
| 3. Key decisions | [docs/decisions/](docs/decisions/), one record per decision |
| Before/after measurements | [docs/measurement_report.md](docs/measurement_report.md), raw output in [benchmarks/](benchmarks/) |
| 4. Memo to Nana | [docs/memo_to_nana.md](docs/memo_to_nana.md) |
| 5. Improvement beyond the brief | [docs/improvement.md](docs/improvement.md), code in [sql/10_stock_drift.sql](sql/10_stock_drift.sql) |

```
.
├── M03_Resources/      supplied schema, load script, csvs and race_test.py (unchanged)
├── sql/                the solution, numbered in run order
├── docs/               diagnosis, decisions, measurements, memo, improvement
├── benchmarks/         query plans, timings and race test output behind the docs
├── scripts/            one-command rebuild, and the race test run ten times
└── checksums.sha256    sha256 of every supplied file, checked before each load
```

| Stage | File |
|---|---|
| Check the server can run the test | [sql/00_preflight.sql](sql/00_preflight.sql) |
| Record every data fault before changing anything | [sql/01_diagnosis.sql](sql/01_diagnosis.sql) |
| New columns and database-generated ids | [sql/02_schema_changes.sql](sql/02_schema_changes.sql) |
| Fix only what the data proves, keep copies of originals | [sql/03_cleanup.sql](sql/03_cleanup.sql) |
| Rules so the faults can't come back | [sql/04_constraints.sql](sql/04_constraints.sql) |
| Stock routine and audit trigger | [sql/05_stock_movements.sql](sql/05_stock_movements.sql) |
| Order placement (the race test contract) | [sql/06_place_order.sql](sql/06_place_order.sql) |
| Indexes | [sql/07_indexes.sql](sql/07_indexes.sql) |
| Monday report | [sql/08_monday_report.sql](sql/08_monday_report.sql) |
| Low stock by category | [sql/09_category_rollup.sql](sql/09_category_rollup.sql) |
| Morning stock drift check | [sql/10_stock_drift.sql](sql/10_stock_drift.sql) |
| Roles and permissions | [sql/11_roles.sql](sql/11_roles.sql) |
| Prove the outputs are right, or stop the build | [sql/12_self_checks.sql](sql/12_self_checks.sql) |

## Running it

You need Docker (or PostgreSQL 18 with `max_connections = 500`), Python 3 and Git. The repository is public.

Tested with: Windows 11, Docker Desktop 4.86 (WSL2), PostgreSQL 18.7 (the script pins `postgres:18.7`), Python 3.14.0 and psycopg2-binary 2.9.13 (pinned in `requirements.txt`).

```powershell
# 0. get the code
git clone https://github.com/techwithsem/DE03-Kloud-Kart-Inventory-Order-Management.git
cd DE03-Kloud-Kart-Inventory-Order-Management

# 1. python environment for the race test
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt

# 2. check the supplied files, start postgres, load the data fresh, run the whole
#    solution and its self checks
.\scripts\reset_and_run.ps1

# 3. the concurrency test, exactly as shipped
. .\scripts\use_env.ps1
cd M03_Resources; python race_test.py; cd ..

# 4. or run it ten times in a row and keep the output
.\scripts\run_race_test_10x.ps1
```

**Database password.** There's no password in this repository. The first time you run a script, `scripts/use_env.ps1` creates a `.env` file with a random password, and every script reads it from there. `.env` is ignored by git and never pushed. `.env.example` shows the format. The Docker database only accepts connections from your own computer, not from the network. If you change the password in `.env` later, remove the old container first with `docker rm -f kloudkart`.

The race test opens 400 connections at once. A default PostgreSQL install allows 100, and the test then fails with errors that never mention connections. `sql/00_preflight.sql` stops early with a clear message if the limit is too low.

If you already have PostgreSQL and `psql`:

```bash
cd M03_Resources
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f schema.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f load.sql
cd ..
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/run_all.sql
```

## Using it day to day

```sql
-- place an order (what the shop's checkout calls)
SELECT * FROM place_order(100001, 5001, 1);

-- restock, return, damage or correct stock (always logged)
SELECT record_stock_movement(5001, 24, 'restock', 'delivery from supplier');

-- monday report: rebuild, then read
SELECT refresh_monday_report();
SELECT * FROM mv_customer_spend_report ORDER BY spend_rank;
SELECT * FROM v_top_100_customers;
SELECT * FROM v_report_months;

-- running total per customer, month by month
SELECT * FROM mv_customer_monthly_spend WHERE customer_id = 100001 ORDER BY order_month;

-- low stock, rolled up through the category tree
SELECT * FROM v_low_stock_by_category ORDER BY category;

-- morning stock check: what started drifting since yesterday
SELECT * FROM stock_drift_check();
SELECT * FROM v_count_these_first LIMIT 20;

-- data quality, before and after cleanup
SELECT * FROM dq.findings_before_after ORDER BY danger_rank;
```

## Going live

`report_settings.as_of_date` is set to 2026-08-31, where the supplied extract ends. On the live server, clear it so the report uses the real date:

```sql
UPDATE report_settings SET as_of_date = NULL;
SELECT refresh_monday_report();
```
