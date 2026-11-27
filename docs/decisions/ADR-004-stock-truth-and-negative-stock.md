# ADR-004: Which stock figure to trust, and negative stock

**Status:** accepted
**Files:** `sql/05_stock_movements.sql`, `sql/10_stock_drift.sql`
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Context

`products.stock_quantity` is what the shop sells against; `inventory_log` is meant to be its history. They agree exactly for 3,879 of 4,023 products. Of the 144 that don't, 50 are explained by duplicated log rows, 39 by recounts marked "recount, not applied", and **55 by nothing in the data**. Separately, 14 products show stock below zero.

## Decision

1. **The stock figure stays the operational truth.** I don't overwrite it from a history that's also wrong.
2. **The 14 negatives are reset to zero** through the logged stock routine, each with a note. Negative stock means units were sold that didn't exist, so the shelf holds zero. Then `CHECK (stock_quantity >= 0)` is switched on.
3. **The 50 proven duplicate log rows are flagged, not deleted.**
4. **Mismatches go on a priced count list** (`v_count_these_first`), which is the [improvement](../improvement.md).

## Alternatives rejected

| Option | Why not |
|---|---|
| Reset stock to whatever the log says | Swaps one wrong number for another |
| Apply the "not applied" recounts now | They may have been left out on purpose, and they're months old |
| Leave negatives alone | The "never below zero" rule couldn't be switched on |
| Delete the duplicate log rows | A tidier trail that can no longer be trusted |

## Cost to Nana if wrong

If one of the 14 really had stock, it shows as out of stock until it's counted. A missed sale costs far less than another oversell, and each reset is logged with a request for a count.

## What I can't stand behind

The right figure for the 55 unexplained products. Only a physical count will tell.
