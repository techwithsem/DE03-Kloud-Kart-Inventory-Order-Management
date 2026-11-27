# Measurement report: before and after

Every figure here comes from a real run. The raw output is in [benchmarks/](../benchmarks/) and can be reproduced with the files named under each section.

## Test setup

| | |
|---|---|
| Machine | Laptop, Intel Core i5-8265U (4 cores, 1.6 GHz), 16 GB RAM |
| Database | PostgreSQL 18.7 in Docker Desktop (WSL2 VM, 8 vCPU, 8 GB), `max_connections=500`, `shared_buffers=256MB`, everything else default |
| Data | The supplied extract: 40,420 customers, 159,384 orders, 336,559 order lines, 282,352 stock movements, 4,023 products, 94 categories |
| Method | Fresh load, `ANALYZE`, then `EXPLAIN (ANALYZE, BUFFERS)`. Each "after" figure was run at least three times and is stable to within about 10%. |

This is an ordinary laptop from 2018. If anything it's slower than Kloud Kart's server.

## 1. The Monday report

**Target:** every customer's total, order count, twelve monthly figures, running total and top-100 ranking, "in seconds".

### Before: the report written the usual way

[benchmarks/naive_report.sql](../benchmarks/naive_report.sql) works out each customer's figures one customer at a time. There's one subquery for the total, one for the count, one for each of the twelve months, and the rank is "how many customers spent more than this one". It produces the same figures as the new report, so the comparison is fair.

Running it for all 40,420 customers would take hours, so I timed it on a slice and scaled up.

| Run | Customers | Time | Per customer |
|---|---|---|---|
| Fresh load, no indexes | 50 | 11.3 s | 0.23 s |
| Fresh load, no indexes | 200 | 52.8 s | 0.26 s |
| **All 40,420 (scaled up)** | 40,420 | **about 3 hours** | |

The plan ([benchmarks/explain_before.txt](../benchmarks/explain_before.txt)) shows why. For every customer and every month, PostgreSQL reads **all 336,559 order lines** again (`Seq Scan on order_items ... loops=45`). The work grows with customers × months × all orders.

### Step 1: change one thing, add two indexes

Indexes on orders by customer and date, and on order lines by order. Same query, nothing else changed ([benchmarks/explain_step1_indexes.txt](../benchmarks/explain_step1_indexes.txt)).

| Customers | Time |
|---|---|
| 200 | 0.11 s |
| 2,000 | 4.2 s |
| 5,000 | 9.7 s |
| 10,000 | 29.9 s |
| 20,000 | 106.4 s |
| **All 40,420 (scaled up)** | **about 7 minutes** |

The per-customer lookups become instant, but the time still grows with the *square* of the number of customers: doubling from 10,000 to 20,000 multiplied the time by 3.6. That's the ranking step. "Count everyone who spent more than me" compares every customer with every other one, which is 1.6 billion comparisons at full size. Indexes can't fix that, because the query itself is the problem.

That also explains Adwoa's 40 minutes. A report built like this gets slower every month as the customer list grows, faster than the business grows, until some Mondays it doesn't finish.

### Step 2: rewrite it to read the data once

[sql/08_monday_report.sql](../sql/08_monday_report.sql) reads every order once, totals it per customer per month (103,165 rows instead of 336,559 order lines), and works everything else out from that smaller set. It uses window functions for the running totals and a single sort for the ranking. The result is stored as a ready-made table, rebuilt on demand.

| What | Time |
|---|---|
| Totalling every order per customer per month, from scratch | 1.6 s |
| **Rebuilding the whole report** (`refresh_monday_report()`) | **5.9 s** (three runs: 5.9, 6.0, 5.9) |
| **Opening the report:** all 40,420 customers, ranked | **18 ms** |
| Opening the top 100 | 0.2 ms |

Raw output: [benchmarks/explain_after.txt](../benchmarks/explain_after.txt).

### A problem I hit on the way, and fixed

My first version took **15.5 s** to rebuild, even though the query underneath took 1.4 s ([benchmarks/explain_after_v1_function_per_row.txt](../benchmarks/explain_after_v1_function_per_row.txt)). The plan showed 11 of those seconds in one aggregate over 103,000 rows. The cause: the small function that returns the report date was being called for every row in each of the 13 monthly filters, about 1.3 million times. PostgreSQL normally inlines a function like that, but it can't when the function carries its own settings, which this one needs for PostgreSQL 17 and later. Computing the date once per query brought the rebuild down to **4.1 s**.

I then added a guard that leaves out orders with impossible quantities. That pushed the rebuild back up to 6.8 s, because the check read all order lines a second time. A small partial index holding only the suspicious lines brought it back to 5.9 s.

### Summary

| | Time for the full report | Change |
|---|---|---|
| Before (as Adwoa's report is likely built, no indexes) | ~3 hours (scaled up from 200 customers) | |
| Indexes only | ~7 minutes (scaled up from 20,000) | 25× faster |
| Rewritten, rebuilt from scratch | **5.9 s** | ~1,800× faster than before |
| Rewritten, opening the stored report | **18 ms** | |

**Does Kloud Kart need a bigger server?** No. The same 2018 laptop went from hours to seconds. A server twice as fast would have turned 3 hours into 1.5. The problem was the shape of the query, not the size of the machine.

## 2. Low stock by category

**Target:** "a couple of seconds".

| What | Time |
|---|---|
| Full rollup through the category tree, live, no stored copy | **15–26 ms** |

[sql/09_category_rollup.sql](../sql/09_category_rollup.sql). It's 94 categories and 4,023 products, so a well-written recursive query has very little to do. No stored copy is needed, which means it can never be out of date. I'm stating plainly that there's no meaningful "before" here: there was no rollup at all, and one hard-coded to four levels would break the rule about depth.

## 3. Placing orders under contention

**Target:** two buyers for the last unit, exactly one wins, every time. Must survive 400 orders in 10 seconds on one product.

| Test (race_test.py, unmodified) | Result |
|---|---|
| 10 complete runs in a row | **10 passed, 0 failed** ([benchmarks/race_test_runs.txt](../benchmarks/race_test_runs.txt)) |
| Two buyers, one unit, 25 rounds per run | 250 of 250 rounds: one winner, one "out of stock", stock 0 |
| Flash sale: 400 buyers, 50 units | 50 sold, 350 "out of stock", 0 errors, stock 0, every run |
| Flash sale wall clock (whole test, incl. 400 connections) | 5.4 to 8.5 s over the final 10 runs (one earlier run hit 13 s; the test only notes anything over 10 s) |
| Ask for 10 when 3 are left | Refused, stock still 3 |
| Audit trail after 12 buyers for 5 units | 5 sold, every sale logged |

### Why the flash sale takes ~6 seconds here, and what that means

On a busy product only one checkout at a time can take stock, so winners queue. Each holds its place in the queue until its order is safely written to disk. I measured that step directly on this laptop:

| One order, no contention | Time |
|---|---|
| Normal (order written safely to disk before confirming) | 50 to 380 ms, very variable |
| Same call with the disk wait switched off (test only) | 5 ms |

So nearly all the time is the laptop's virtual disk (Docker Desktop on Windows) confirming writes, not the ordering logic. The 50 winners queue for roughly 50 × that wait. Losers don't write anything, so they get their "out of stock" as soon as the stock hits zero.

- **On this laptop:** 400 buyers usually served in 6 to 8 seconds. That keeps up with the 400 in 10 seconds marketing expects, with no errors.
- **On a server with an ordinary SSD** (around 1 ms per write) the same queue would clear in well under a second. I haven't measured that, because I don't have access to Kloud Kart's server.

I kept the safe setting. Switching off the disk wait would make the flash sale fast on any machine, but a power cut could then lose the last fraction of a second of confirmed orders. For a shop taking payments, that's the wrong trade.

## 4. Morning stock drift check (the improvement)

| What | Time |
|---|---|
| Full drift list, all products, priced and ranked | 0.24 to 0.66 s |

## What I didn't measure

- Kloud Kart's own server. Every figure above is from the laptop described at the top.
- A real flash sale with real customers. The test is a faithful simulation (400 connections fired together), not the real thing.
- The report at larger data sizes. The new report reads every order once, so its time should grow in step with the number of orders. It doesn't have the square-of-customers growth the old one had.
