# DE03-Kloud-Kart-Inventory-Order-Management

Kloud Kart was selling the same last unit twice, and its Monday spending report took about 40 minutes. This fixes both on its one PostgreSQL server, adds a low-stock rollup through the category tree and a stock trail an auditor can follow, and documents what's wrong with the data.

**Start with [docs/summary.md](docs/summary.md):** the results and where everything is, on one page.

## Deliverables

| Deliverable | Where |
|---|---|
| 1. Data diagnosis | [docs/data_diagnosis.md](docs/data_diagnosis.md) |
| 2. Working SQL solution | [sql/](sql/), files 00 to 11, run in order by [run_all.sql](sql/run_all.sql) |
| 3. Key decisions | [docs/decisions/](docs/decisions/) |
| Before/after measurements | [docs/measurement_report.md](docs/measurement_report.md), raw output in [benchmarks/](benchmarks/) |
| 4. Memo to Nana | [docs/memo.md](docs/memo.md) |
| 5. Improvement beyond the brief | [docs/improvement.md](docs/improvement.md) |

`M03_Resources/` is the supplied bundle, unchanged.

## Running it

Needs Docker Desktop (running), Python 3 and Git. Tested on Windows 11 with Python 3.14.0. The PostgreSQL image is pinned to `postgres:18.7` in `main.py`, and package versions are pinned in `requirements.txt`.

```bash
git clone https://github.com/techwithsem/DE03-Kloud-Kart-Inventory-Order-Management.git
cd DE03-Kloud-Kart-Inventory-Order-Management
python -m venv .venv

# windows
.venv\Scripts\python -m pip install -r requirements.txt
# macos / linux
.venv/bin/python -m pip install -r requirements.txt

# start postgres, load fresh, run everything and the self checks
python main.py
# the race test, exactly as shipped
python main.py race
# ten runs, saved to benchmarks/race_test_10_runs.txt
python main.py race 10
# one sql file
python main.py sql sql/08_monday_report.sql
# a psql prompt (\q to quit)
python main.py psql
```

- **A clean build** ends with `self checks passed`, the before/after table of data faults and `done. next: python main.py race`, and exits with code 0. Any failure stops it with an `error:` line and a non-zero exit code.
- **Running `race_test.py` by hand:** set `DATABASE_URL` first (it's in `.env`), then run `python race_test.py` from `M03_Resources/`. `python main.py race` does this for you.
- **Password:** the first run creates a private `.env` with a random password. Git ignores it, and the database only accepts connections from your own computer.
## Using it

```sql
SELECT * FROM place_order(100001, 5001, 1);
SELECT * FROM v_low_stock_by_category ORDER BY category;
SELECT * FROM v_count_these_first LIMIT 20;
SELECT * FROM dq.findings_before_after ORDER BY danger_rank;
```

**The Monday report** is stored, so rebuild it before reading it:

```sql
SELECT refresh_monday_report();
SELECT * FROM v_top_100_customers;
```

**Before going live,** change the report date. It's fixed at 2026-08-31, where the extract ends, so "the last 12 months" matches the data. Clear it so the report uses today's date:

```sql
UPDATE report_settings SET as_of_date = NULL;
SELECT refresh_monday_report();
```
