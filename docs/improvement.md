# Improvement beyond the brief: a morning stock drift check

**Files:** [sql/10_stock_drift.sql](../sql/10_stock_drift.sql)
**For:** Nana, and whoever does the stock counts

## The problem it solves

The brief fixes overselling from now on. It doesn't answer the question Nana actually started with: *"my stock counts no longer match reality closely enough to trust."* After the fix, a wrong count still means a wrong answer. The shop will refuse a customer when there's stock on the shelf, or keep selling when the shelf is empty and the number says otherwise.

Today nobody finds out a count is wrong until a customer does.

## What I built

Every product's stock figure should equal the sum of every movement in its log. That's true for 3,879 of 4,023 products, so it's the rule the data was meant to follow. When the two disagree, something changed the stock without leaving a trail, or the trail is wrong.

| Piece | What it does |
|---|---|
| `v_stock_drift` | Every product whose stock and log disagree: by how many units, the value at risk in cedis, sales in the last 30 days, and the most likely cause in plain words. |
| `v_count_these_first` | The same list in the order to count it: most money at risk first, fastest sellers breaking ties. That's the list to hand to the warehouse. |
| `stock_drift_check()` | Meant to run every morning. It saves a snapshot and returns only what's **new or worse since the last run**, so yesterday's known problems don't hide today's. |

Duplicate log rows are flagged and ignored, so they don't show up as false alarms.

## What it found on the supplied data

On a fresh load, after cleanup:

- **94 products** have a stock figure that disagrees with their own history, with **₵759,181** of stock in doubt.
- **39** are explained: a recount was written down as *"recount, not applied"* and never used.
- **55** have no explanation in the data. The stock figure is lower than the history says, which points to sales, losses or damage that were never recorded.
- **The top 20 products on the count list carry ₵660,176 of that, 87%.** Counting 20 products, not 4,023, deals with most of the risk.

The top of the list:

| Count first | Product | On record | Per log | Value at risk | Sold, last 30 days |
|---|---|---|---|---|---|
| 1 | Hisense Iron Plus | 2 | 7 | ₵106,757 | 28 |
| 2 | Yamaha Fan | 5 | 10 | ₵97,704 | 17 |
| 3 | Nestle Sugar and Salt Lite | 60 | 64 | ₵80,577 | 26 |
| 4 | Unilever Oil 3 | 12 | 15 | ₵64,725 | 43 |
| 5 | HP Smart TV Mini | 60 | 57 | ₵55,733 | 9 |

## Shown working

[benchmarks/stock_drift_demo.sql](../benchmarks/stock_drift_demo.sql) runs inside a transaction that's rolled back, so it changes nothing. Its output is in [benchmarks/stock_drift_demo.txt](../benchmarks/stock_drift_demo.txt):

1. The first check lists all 94 products, ₵759,181.
2. Someone changes a product's stock by hand. The audit trigger logs it anyway, as a correction "changed directly, not through the stock routines".
3. A movement is written to the log but never applied to stock (the pattern found in the data).
4. **The next check returns only that one product**, marked "new since last check", with the likely cause. The 94 known ones don't drown it out.

The check takes about a quarter of a second.

## What it's worth

- **Fewer refunds.** Every product on the list is a product where the shop's idea of stock is wrong. The ones showing *more* than the log are the next oversell waiting to happen: the database will happily sell units the trail says aren't there.
- **A count list that pays for itself.** Instead of counting all 4,023 products, the warehouse starts at the top of a priced list. The top 20 cover most of the money at risk.
- **Problems caught the next morning, not by customers.** The overnight check tells Nana which products started drifting yesterday, while people still remember what happened.
- **It keeps the new trail honest.** Once the old drift is counted and corrected, a new entry on the list means something bypassed the proper routines. That's exactly what an auditor would want flagged.

## How to use it

```sql
-- every morning (or scheduled with cron / pg_cron if the team adds it later)
SELECT * FROM stock_drift_check();

-- the count list for the warehouse
SELECT * FROM v_count_these_first LIMIT 20;

-- after counting, record the correction through the logged routine
SELECT record_stock_movement(5094, -36, 'correction', 'physical count 2026-09-02 by Kofi');
```

## Limits

It catches drift between the stock figure and its own log. It can't catch a shelf that's wrong while both records agree, for example stolen goods nobody recorded. Only a physical count finds that.
