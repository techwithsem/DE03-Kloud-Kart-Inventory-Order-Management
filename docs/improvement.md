# Improvement beyond the brief: a morning stock drift check

**Code:** [sql/10_stock_drift.sql](../sql/10_stock_drift.sql). **For:** Nana and whoever does the stock counts.

## The problem

The brief stops overselling from now on. It doesn't fix what Nana started with: *"my stock counts no longer match reality."* A wrong count still means the shop refuses customers when there's stock, or sells stock that isn't there, and today nobody notices until a customer does.

## What I built

A product's stock should equal the sum of its logged movements. That holds for 3,879 of 4,023 products, so any mismatch means something changed stock without a trail, or the trail is wrong. Flagged duplicate log rows are ignored, so they don't raise false alarms.

| Piece | What it does |
|---|---|
| `v_stock_drift` | Every mismatched product: by how many units, the value at risk in cedis, sales in the last 30 days, and the likely cause in plain words |
| `v_count_these_first` | The same list in counting order: most money at risk first, fastest sellers breaking ties |
| `stock_drift_check()` | Runs each morning, saves a snapshot, and returns only what's **new or worse since the last run**. Keeps 90 days of history. |

## What it found

- **94 products** don't add up, with **₵759,181** in doubt.
- 39 are explained by recounts that were noted ("recount, not applied") but never used.
- 55 have no explanation: stock is lower than the log says, which points to unrecorded sales, losses or damage.
- **The top 20 carry ₵660,176 (87%)**, so counting 20 products, not 4,023, covers most of the risk.

| # | Product | On record | Per log | At risk | Sold, last 30 days |
|---|---|---|---|---|---|
| 1 | Hisense Iron Plus | 2 | 7 | ₵106,757 | 28 |
| 2 | Yamaha Fan | 5 | 10 | ₵97,704 | 17 |
| 3 | Nestle Sugar and Salt Lite | 60 | 64 | ₵80,577 | 26 |
| 4 | Unilever Oil 3 | 12 | 15 | ₵64,725 | 43 |
| 5 | HP Smart TV Mini | 60 | 57 | ₵55,733 | 9 |

## Shown working

[stock_drift_demo.sql](../benchmarks/stock_drift_demo.sql) runs inside a transaction that's rolled back, so it changes nothing. Output: [stock_drift_demo.txt](../benchmarks/stock_drift_demo.txt).

1. The first check lists all 94 products.
2. A hand-typed stock change is caught and logged by the audit trigger.
3. A movement is logged but never applied to stock (the pattern found in the data).
4. **The next check returns only that one product**, marked "new since last check".

It takes about a quarter of a second.

## What it's worth

- **Fewer refunds.** Every product on the list has wrong stock. Those showing more on record than in the log are the next oversell.
- **A short count list.** The warehouse starts at the top of a priced list instead of counting everything.
- **Next-day warning.** Problems surface the morning after, while people still remember what happened.
- **Keeps the trail honest.** Once the old drift is cleared, any new entry means something bypassed the proper routines.

## Using it

```sql
SELECT * FROM stock_drift_check();
SELECT * FROM v_count_these_first LIMIT 20;
SELECT record_stock_movement(5094, -36, 'correction', 'physical count 2026-09-02 by Kofi');
```

**Limit:** it can't catch a shelf that's wrong while both records agree, for example unrecorded theft. Only a physical count finds that.
