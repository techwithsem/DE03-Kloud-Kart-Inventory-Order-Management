# Summary

Kloud Kart (about 4,000 orders a day, one PostgreSQL server) was selling the same last unit twice, and its Monday spending report took about 40 minutes. This project fixes both on the same server, with plain PostgreSQL: no new services and no new bills.

## Results against Nana's targets

| Target | Before | After | Proof |
|---|---|---|---|
| Never sell stock that isn't there | 14 products oversold | `race_test.py` unmodified: 10 of 10 runs passed | [race_test_10_runs.txt](../benchmarks/race_test_10_runs.txt) |
| Flash sale: 400 orders in 10 s | Oversold | 400 buyers for 50 units: exactly 50 sold, 0 errors, 3.1–4.7 s | [measurement_report.md](measurement_report.md) |
| Monday report "in seconds" | ~40 min (~3 h measured with no indexes) | 5.9 s to rebuild, 18 ms to open | [measurement_report.md](measurement_report.md) |
| Low stock by category "in a couple of seconds" | Didn't exist | 15–26 ms, at any depth of the tree | [measurement_report.md](measurement_report.md) |
| A stock trail an auditor can follow | No link to orders, no "stock after" | Every movement logged with its order, stock after and who made it, even hand-typed changes | [ADR-008](decisions/ADR-008-audit-trail.md) |
| A bigger server? | Already priced | Not needed: the same laptop went from hours to seconds | [ADR-002](decisions/ADR-002-report-speed.md) |

## How

- **Overselling:** the stock check and the stock decrement are one statement, so no two buyers can both see the last unit. Triggers alone wouldn't have worked: the second buyer would get an error, not "out of stock". ([ADR-001](decisions/ADR-001-overselling.md))
- **Report speed:** the report reads the orders once instead of once per figure per customer, and the result is stored and rebuilt on demand. ([ADR-002](decisions/ADR-002-report-speed.md))
- **Category rollup:** a recursive query that handles any depth and refuses category loops. ([ADR-007](decisions/ADR-007-category-rollup.md))
- **Data:** every fault was recorded before anything was changed, only what the data proves was fixed, and every original row was kept. ([ADR-006](decisions/ADR-006-cleanup-rules.md))

## What the data showed

17 faults, ranked by what they cost Nana ([data_diagnosis.md](data_diagnosis.md)). The worst:

1. **Negative stock** on 14 products, ₵20,628 sold that didn't exist.
2. **The stock trail doesn't match the orders**, product by product.
3. **Six impossible order lines** (999 and 9,999 units), worth ₵3.07m, which made a 2-item customer the top spender.
4. **1,590 order totals off by exactly 10% or 25%**, which looks like a checkout pricing fault.
5. **Order status spelled 15 ways**, so "completed" found only 1 in 5 completed orders.

## Beyond the brief

A **morning stock drift check** lists products whose stock doesn't match their own log, priced and in counting order. Today that's 94 products and ₵759,181. Counting the top 20 covers 87% of it. ([improvement.md](improvement.md))

## Not covered

- Speed on Kloud Kart's own server, and with real flash-sale traffic.
- The right stock figure for 55 products: only a physical count can tell.
- Whether customers paid the order total or the item prices on the 1,590 mismatched orders: finance should check.

## Where everything is

| Deliverable | File |
|---|---|
| 1. Data diagnosis | [data_diagnosis.md](data_diagnosis.md) |
| 2. Working SQL solution | [sql/](../sql/), run by `python main.py` |
| 3. Key decisions | [decisions/](decisions/) (ADR-001 to ADR-010) |
| Before and after figures | [measurement_report.md](measurement_report.md) |
| 4. Memo to Nana | [memo.md](memo.md) |
| 5. Improvement beyond the brief | [improvement.md](improvement.md) |
