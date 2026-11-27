# ADR-002: A fast Monday report, and no bigger server

**Status:** accepted
**Files:** `sql/08_monday_report.sql`, `sql/07_indexes.sql`
**Figures from:** [measurement_report.md](../measurement_report.md) and the raw output in [benchmarks/](../../benchmarks/)

## Context

Adwoa's report takes about 40 minutes and sometimes doesn't finish. The brief wants totals, counts, 12 monthly figures, a running total and a top 100 "in seconds". Rebuilt the usual way (each figure per customer by its own query), it takes ~3 hours with no indexes and ~7 minutes with two. The time grows with the *square* of the number of customers, because the ranking compares every customer with every other.

## Decision

1. **Read the orders once,** totalling per customer per month (103,165 rows, instead of re-reading 336,559 lines for every figure).
2. **Derive everything else from that set:** monthly columns from filtered sums, running totals from a window function, the ranking from one sort.
3. **Store the result** as a materialized view, rebuilt by `refresh_monday_report()`. The rebuild is concurrent, so old figures stay readable meanwhile.
4. **Add only the indexes the measurements justified:** orders by customer and date; order lines by order and by product; the stock log by product and by order; and a partial index on the few impossible-quantity lines.

Result: **5.9 s to rebuild, 18 ms to open, 0.2 ms for the top 100.**

## Bigger server?

No. The same 2018 laptop went from hours to seconds. A server twice as fast would only halve the old 3 hours, cost money every month, and lose ground again as customers grow.

## Alternatives rejected

| Option | Why not |
|---|---|
| Bigger server | Doesn't fix the square-of-customers growth; adds a monthly bill; ruled out by the brief |
| Indexes alone | ~3 h down to ~7 min: still not seconds, and still getting worse |
| A live query, nothing stored | About 6 s for every reader, competing with checkout. Stored, it opens in 18 ms. |
| A summary kept up to date by triggers on every order | Adds work to every checkout, including the 400 in a flash sale |

## Trade-off

The report is only as fresh as its last rebuild. That's fine for a weekly report: rebuild on Monday morning (6 s), or schedule it.

## Cost to Nana if wrong

If nobody rebuilds it, it shows last week's figures. Every row carries its as-of date, so stale figures are visible rather than silent. At 10× the data, a rebuild should take about a minute.

## What a naive build would have cost

The per-customer version slows down faster than the business grows. The bigger server would have been followed by an even bigger one.
