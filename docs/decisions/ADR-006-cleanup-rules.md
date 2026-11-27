# ADR-006: What gets fixed, flagged or left alone

**Status:** accepted
**Files:** `sql/03_cleanup.sql`, `sql/04_constraints.sql`
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Context

The data has undocumented faults, "not everything that looks wrong is wrong", Nana's team lives with whatever I change, and nobody is available to ask.

## Decision

**Change a row only when the data itself proves the right value, and keep the original.** Everything else is flagged and left as it is.

| Problem | Action | Proof |
|---|---|---|
| Status spelled 15 ways | Mapped to 5 values; originals in `dq.order_status_original` | `complete`/`completed` can't mean different things |
| Lines entered twice | Copy removed on 527 orders; kept in `dq.removed_order_items` | The total matches only without the copy (76 others match with it, and stay) |
| No price or zero price | 285 repriced; logged in `dq.order_item_price_fixes` | The total matches the list price; 15 unconfirmed stay |
| Quantities of 999 / 9,999 | 5 of 6 corrected; originals in `dq.order_item_quantity_fixes` | The total pins down the real quantity |
| Lines with no order | 692 moved to quarantine | No customer or date, and they block the foreign key |
| Category loop and dead end | Promotions and Clearance made top level; logged in `dq.category_fixes` | Promotions is the broader name |
| Movements logged twice | 50 proven doubles flagged, not deleted | Stock matches only without the copy; the other 469 repeats agree with stock |
| Negative stock | Reset through the logged routine (ADR-004) | Stock can't physically be negative |

Then rules stop the faults coming back: allowed statuses, real customers and products, required key columns, positive quantities (at most 100) and prices, no negative stock, no category loops. Rules that old rows break are added `NOT VALID`, so they check new rows only.

**Left alone on purpose:** historic discounted prices, zero-change stock takes, duplicate product names, Nigerian customers, Accra's spellings, header totals (ADR-003), unknown customers and future dates (ADR-005), and duplicate emails (ADR-010).

## Alternatives rejected

- **Delete everything suspicious:** the database looks cleanest and becomes least trustworthy, and ₵1.5m of possibly real orders would be thrown away.
- **Fix nothing:** reports are built on 15 status spellings and double entries, and the "never oversell" rule can't be switched on.

## Cost to Nana if wrong

Every change can be reversed from the `dq` tables.
