# ADR-009: What "low stock" means

**Status:** accepted
**Files:** `sql/02_schema_changes.sql` (`products.reorder_level`), `sql/09_category_rollup.sql`
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Context

The brief doesn't define "low", and the data has no reorder levels. Stock varies widely: a quarter of products hold 2 or fewer units, the median is 12, and the top tenth hold over 220.

## Decision

Each product gets a `reorder_level`, defaulting to **10**. Low means above 0 and at or below that level; out of stock is reported separately. The team can set levels per product without any code change.

## Alternatives rejected

| Option | Why not |
|---|---|
| One fixed number in the query | Changing it means editing the query |
| Days of cover from sales speed | Better in principle, but the sales log doesn't agree with orders yet, so it would look precise and be wrong |
| A percentage of normal stock | There's no "normal stock" figure |

## Cost to Nana if wrong

Set too low, fast sellers look fine until they're nearly gone. Set too high, the list gets noisy and people stop reading it. Either way it's fixed per product.
