# ADR-002: Making the Monday report fast, and whether a bigger server is needed

**Status:** accepted
**Files:** `sql/08_monday_report.sql`, `sql/07_indexes.sql`. Evidence in `docs/measurement_report.md`.
**Figures from:** [measurement_report.md](../measurement_report.md) and the raw output in [benchmarks/](../../benchmarks/)

## Context

Adwoa's report takes about 40 minutes and some Mondays doesn't finish. Someone has priced a bigger server. The brief wants totals, counts, twelve monthly figures, a running total and a top-100 ranking "in seconds on an ordinary laptop".

I rebuilt the report the way it's usually first written, with each figure worked out per customer by its own query, and measured it. On a fresh load with no indexes it takes about 0.26 s per customer, roughly **3 hours** for 40,420 customers. With two indexes it drops to about **7 minutes**, but it still grows with the *square* of the number of customers, because ranking by "count everyone who spent more than me" compares every customer with every other.

## Decision

1. **Read the orders once.** One pass totals every order per customer per month. That's 103,165 rows instead of re-reading 336,559 order lines for every figure.
2. **Work everything else out from that small set.** Twelve monthly columns come from filtered sums, the running total from a window function, and the ranking from a single sort.
3. **Store the result.** The finished report is kept as a ready table (a materialized view) and rebuilt by `refresh_monday_report()`. The rebuild runs "concurrently", so the old figures stay readable while the new ones are worked out.
4. **Indexes where the measurements showed they matter:** orders by customer and date, order lines by order and by product, the stock log by product and by order. Plus one tiny index on the few lines with impossible quantities.

Result on the same laptop: **5.9 s to rebuild, 18 ms to open, 0.2 ms for the top 100.**

## Is a bigger server needed?

No. The report went from hours to seconds on a 2018 laptop. A machine twice as fast would have taken the old report from 3 hours to 1.5. Changing the way the report is worked out took it to 6 seconds. The bigger server would have cost money every month and still left Adwoa waiting, and the wait would keep growing with the customer list.

## Alternatives I rejected

| Option | Why not |
|---|---|
| Bigger server | Doesn't fix a report that grows with the square of customers. Monthly bill. Ruled out by the brief. |
| Indexes alone | Measured: 3 hours down to 7 minutes. A big improvement, still not "seconds", and still getting worse as customers grow. |
| A live query with no stored copy | 1.6 s for the base totals and about 6 s in all. Acceptable, but every person who opens it pays that, and it competes with checkout during the day. Stored, it's 18 ms. |
| A summary table updated by triggers on every order | Always up to date, but it adds work to every checkout, including the 400 in a flash sale. That's exactly the wrong place to add work. |
| Rebuilding every few minutes | Not needed for a weekly report. Easy to add if someone wants it. |

## Trade-off

The stored report is only as fresh as its last rebuild. If Adwoa rebuilds it at 8:00 on Monday, an order at 8:05 isn't in it. For a weekly spending report that's fine. If she needs live figures, the rebuild takes 6 seconds and can be run any time, or scheduled.

## Cost to Nana if this is wrong

If someone forgets to rebuild, the report shows last week's figures. Every row carries the date it's "as of", so stale figures are visible rather than silent. If the business grows tenfold, the rebuild should take about a minute. That's still fine for a weekly report, and nowhere near the old report's square-of-customers growth.

## What a naive build would have cost later

The per-customer version gets slower every week as customers sign up, faster than the business grows. It would have gone from 40 minutes to hours within a year, and the bigger server would have been followed by an even bigger one.
