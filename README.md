# DE03-Kloud-Kart-Inventory-Order-Management

Kloud Kart (about 4,000 orders a day, one PostgreSQL server) was selling the same last unit twice, and its Monday spending report took about 40 minutes. This repository fixes both, adds a low-stock rollup through the category tree and a stock trail an auditor can follow, and documents what's wrong with the data. It's plain PostgreSQL: no new services and no new bills.

## Deliverables

| Deliverable | Where |
|---|---|
| 1. Data diagnosis | [docs/data_diagnosis.md](docs/data_diagnosis.md) |
| 2. Working SQL solution | [sql/](sql/), run in order by [sql/run_all.sql](sql/run_all.sql) |
| 3. Key decisions | [docs/decisions/](docs/decisions/) |
| Before/after measurements | [docs/measurement_report.md](docs/measurement_report.md), with raw output in [benchmarks/](benchmarks/) |
| 4. Memo to Nana | [docs/memo_to_nana.md](docs/memo_to_nana.md) |
| 5. Improvement beyond the brief | [docs/improvement.md](docs/improvement.md) |

| SQL file | Purpose |
|---|---|
| [00_preflight](sql/00_preflight.sql) | Check the server can run the test |
| [01_diagnosis](sql/01_diagnosis.sql) | Record every data fault before changing anything |
| [02_schema_changes](sql/02_schema_changes.sql) | New columns, database-generated ids |
| [03_cleanup](sql/03_cleanup.sql) | Fix only what the data proves, keeping the originals |
| [04_constraints](sql/04_constraints.sql) | Rules so the faults can't come back |
| [05_stock_movements](sql/05_stock_movements.sql) | Stock routine and audit trigger |
| [06_place_order](sql/06_place_order.sql) | Order placement (the race test contract) |
| [07_indexes](sql/07_indexes.sql) | Indexes |
| [08_monday_report](sql/08_monday_report.sql) | Monday report |
| [09_category_rollup](sql/09_category_rollup.sql) | Low stock by category |
| [10_stock_drift](sql/10_stock_drift.sql) | Morning stock drift check |
| [11_roles](sql/11_roles.sql) | Roles and permissions |
| [12_self_checks](sql/12_self_checks.sql) | Prove the outputs are right, or stop the build |

`M03_Resources/` is the supplied bundle, unchanged; [checksums.sha256](checksums.sha256) proves it. [main.py](main.py) is the one-command rebuild and race test runner; `scripts/` holds the same in PowerShell.

## Running it

You need Docker Desktop, Python 3 and Git. It was tested on Windows 11 with Docker Desktop 4.86, PostgreSQL 18.7 (pinned), Python 3.14.0 and psycopg2-binary 2.9.13 (pinned).

```powershell
git clone https://github.com/techwithsem/DE03-Kloud-Kart-Inventory-Order-Management.git
cd DE03-Kloud-Kart-Inventory-Order-Management

python -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt   # macOS/Linux: .venv/bin/python -m pip ...

# check the supplied files, start postgres, load fresh, run everything plus the self checks
python main.py

# the race test, exactly as shipped
python main.py race

# or ten runs in a row, saved to benchmarks/race_test_runs.txt
python main.py race 10
```

Docker Desktop has to be running. `psql` runs inside the container, so you don't need it installed. `main.py` uses the `.venv` Python for the race test automatically, so there's nothing to activate. The same commands work on Windows, macOS and Linux.

**One file at a time.** The files build on each other, so run them in number order after a fresh load. Any file can be re-run safely.

```powershell
python main.py sql sql/08_monday_report.sql
python main.py psql        # interactive prompt, \q to quit
```

The PowerShell scripts in `scripts/` do the same jobs, if you prefer them: `reset_and_run.ps1`, `run_race_test_10x.ps1`, and `use_env.ps1` to load `.env` into a session.

**Password.** None is stored in this repository. The first command you run creates a private `.env` with a random password, and git ignores it; `.env.example` shows the format. The database only accepts connections from your own computer. If you change the password, run `docker rm -f kloudkart` first.

**Connections.** The race test opens 400 connections, and PostgreSQL's default limit is 100. The script sets it to 500, and `00_preflight` stops with a clear message if it's lower.

## Using it

```sql
SELECT * FROM place_order(100001, 5001, 1);
SELECT record_stock_movement(5001, 24, 'restock', 'delivery from supplier');

SELECT refresh_monday_report();
SELECT * FROM mv_customer_spend_report ORDER BY spend_rank;
SELECT * FROM v_top_100_customers;
SELECT * FROM v_report_months;
SELECT * FROM mv_customer_monthly_spend WHERE customer_id = 100001 ORDER BY order_month;

SELECT * FROM v_low_stock_by_category ORDER BY category;

SELECT * FROM stock_drift_check();
SELECT * FROM v_count_these_first LIMIT 20;

SELECT * FROM dq.findings_before_after ORDER BY danger_rank;
```

**Going live:** the report date is set to 2026-08-31, where the extract ends. Clear it so the report uses the real date:

```sql
UPDATE report_settings SET as_of_date = NULL;
SELECT refresh_monday_report();
```
