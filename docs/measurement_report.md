# Measurement report: before and after

Every figure comes from a real run. Raw output is in [benchmarks/](../benchmarks/).

**Setup:** a 2018 laptop (Intel i5-8265U, 4 cores, 16 GB) running PostgreSQL 18.7 in Docker Desktop (WSL2, 8 vCPU, 8 GB), with `max_connections=500`, `shared_buffers=256MB` and other settings at their defaults. Data is the supplied extract: 40,420 customers, 159,384 orders, 336,559 order lines, 282,352 stock movements, 4,023 products and 94 categories. Each run used a fresh load, then `ANALYZE`, then `EXPLAIN (ANALYZE, BUFFERS)`. Every "after" figure was run at least three times and stayed within about 10%.

## 1. Monday report (target: seconds)

**Before.** [monday_report_before.sql](../benchmarks/monday_report_before.sql) builds the report the usual way: one subquery per figure, per customer, with the rank found by counting everyone who spent more. It returns the same figures as the new report. A full run would take hours, so I timed slices:

| Version | Customers | Time |
|---|---|---|
| No indexes | 50 | 11.3 s |
| No indexes | 200 | 52.8 s |
| No indexes, scaled up | 40,420 | **~3 hours** |
| With 2 indexes (the only change) | 200 / 2,000 / 5,000 | 0.11 s / 4.2 s / 9.7 s |
| With 2 indexes | 10,000 / 20,000 | 29.9 s / 106.4 s |
| With 2 indexes, scaled up | 40,420 | **~7 minutes** |

Without indexes, the plan re-reads all 336,559 order lines for every customer and month ([monday_report_before_timing.txt](../benchmarks/monday_report_before_timing.txt)). Indexes fix the lookups, but the time still grows with the *square* of the customer count: doubling from 10,000 to 20,000 customers made it 3.6× slower. That's the ranking step, which compares every customer with every other one. It's also why Adwoa's report keeps getting slower.

**After.** [08_monday_report.sql](../sql/08_monday_report.sql) reads the orders once and totals them per customer per month, giving 103,165 rows. The monthly columns, running totals (window functions) and ranking (one sort) are all worked out from that. The result is stored and rebuilt on demand ([monday_report_after_timing.txt](../benchmarks/monday_report_after_timing.txt)).

| Step | Time |
|---|---|
| Base totals from scratch | 1.6 s |
| **Full rebuild** (`refresh_monday_report()`) | **5.9 s** (5.9, 6.0, 5.9) |
| **Open the report:** 40,420 customers, ranked | **18 ms** |
| Top 100 | 0.2 ms |

**Problems found and fixed along the way:**
- **The first version rebuilt in 15.5 s.** The report-date function ran about 1.3 million times, once per row in 13 monthly filters, because a function with its own settings can't be inlined. Computing the date once per query brought it to 4.1 s.
- **Excluding impossible quantities took it back up to 6.8 s**, because that check re-read every order line. A partial index on just those lines brought it to 5.9 s.

| Version | Full report | vs before |
|---|---|---|
| Before | ~3 hours | |
| Indexes only | ~7 minutes | 25× faster |
| Rewritten, rebuilt | **5.9 s** | ~1,800× faster |
| Rewritten, opened | **18 ms** | |

**Bigger server?** No. The same laptop went from hours to seconds. Twice the hardware would have taken 3 hours to 1.5.

## 2. Low stock by category (target: a couple of seconds)

The full live rollup takes **15–26 ms** ([09_category_rollup.sql](../sql/09_category_rollup.sql)). There's no "before": no rollup existed, and one hard-coded to four levels would break the brief.

## 3. Orders under contention

| `race_test.py`, unmodified | Result |
|---|---|
| 10 complete runs in a row | **10 passed** ([race_test_10_runs.txt](../benchmarks/race_test_10_runs.txt)) |
| Two buyers, one unit (25 rounds per run) | 250/250: one winner, one "out of stock", stock 0 |
| Flash sale: 400 buyers, 50 units | 50 sold, 350 refused, 0 errors, every run |
| Flash sale wall clock, incl. opening 400 connections | 5.4–8.5 s over the final 10 runs (once 13 s) |
| 10 requested, 3 in stock | Refused, stock still 3 |
| Audit trail: 12 buyers, 5 units | All 5 sales logged |

**Why about 6 s here.** Only one checkout at a time can take stock from a product, and each holds its turn until its order is safely on disk. On this laptop that disk write takes 50–380 ms; with the wait switched off (test only) a call takes 5 ms. Losers write nothing, so the queue is roughly 50 winners × the disk write. On a normal server SSD (about 1 ms per write) it should clear in well under a second. **That figure is an estimate, not measured.** I kept the safe setting, because switching the wait off could lose confirmed orders in a power cut.

## 4. Morning stock drift check

The full priced list takes 0.24–0.66 s.

## Not measured

- Kloud Kart's own server.
- A real flash sale with real customers.
- Larger data. The new report reads each order once, so its time should grow in step with the number of orders, without the old square-of-customers growth.
