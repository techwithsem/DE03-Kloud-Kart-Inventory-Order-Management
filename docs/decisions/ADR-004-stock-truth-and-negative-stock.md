# ADR-004: Which stock figure to trust, and what to do with negative stock

**Status:** accepted
**Files:** `sql/05_stock_movements.sql`, `sql/10_stock_drift.sql`
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Context

There are two records of stock. `products.stock_quantity` is the number the shop sells against. `inventory_log` is meant to be the history of every movement. For 3,879 of the 4,023 products, the history adds up exactly to the stock figure. That tells us how the two are meant to relate. For 144 products they don't agree, and 14 products show stock below zero.

Looking into the 144:

- For 50, the history contains the same movement logged twice. Remove the copy and it matches.
- For 39, the history has a correction marked *"recount, not applied"*. Someone counted, wrote it down, and never changed the stock.
- **55 have no explanation I could find in the data.**

## Decision

1. **The stock figure stays the operational truth.** It's what customers buy against, and nobody has counted the shelves for me. I don't overwrite it from the history.
2. **The 14 negative products are reset to zero**, through the proper stock routine, so each reset is itself a logged correction with a note. Negative stock means units were sold that didn't exist; what's on the shelf is zero. After that, a hard rule stops stock going negative ever again.
3. **Proven duplicate history rows (50) are flagged, not deleted.** An audit trail you edit afterwards isn't an audit trail.
4. **The 144 mismatches go on a priced list** (`v_count_these_first`) so the team counts the most expensive problems first. This became the improvement beyond the brief (see `docs/improvement.md`).

## Alternatives I rejected

| Option | Why not |
|---|---|
| Reset every stock figure to what the history says | The history is wrong too (duplicates, recounts never applied, sales missing). I'd be swapping one wrong number for another on 144 products. |
| Apply the "recount, not applied" corrections now | They might have been left unapplied on purpose. A count from months ago is not today's stock either. |
| Leave negative stock alone | Then the "never below zero" rule can't be switched on, and the shop goes on promising units it doesn't have. |
| Delete the duplicate history rows | It would make the numbers tidy and the trail untrustworthy. |

## Cost to Nana if this is wrong

If one of the 14 really has stock (say someone restocked without logging it), resetting it to zero means it shows as out of stock until it's counted. That's a missed sale, which is a much smaller cost than another oversold customer. Each reset is in the log with a note asking for a physical count.

## What I can't stand behind

For the 55 unexplained products I don't know which figure is right. Only a physical count settles that.
