# ADR-009: What "low stock" means

**Status:** accepted
**Files:** `sql/02_schema_changes.sql` (`products.reorder_level`), `sql/09_category_rollup.sql`
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Context

The brief asks for low-stock visibility but doesn't say what "low" is. There's no reorder level anywhere in the data. Stock levels vary hugely: a quarter of products have 2 or fewer units, the median is 12, and the top tenth have over 220.

## Decision

- Each product gets a `reorder_level`, **10 units by default**. Low stock means at or below that level and above zero. Out of stock is reported separately, because it's a different problem.
- The team can set a different level per product as they learn what each needs. Nothing else has to change.

## Alternatives I rejected

| Option | Why not |
|---|---|
| One fixed number in the query | The first time a slow seller and a best seller need different levels, someone edits a query. A column is easier to maintain. |
| Days of cover based on sales speed | Better in principle, but the sales history in the log doesn't agree with the orders (see the diagnosis), so it would be precise-looking and wrong. Worth doing once the trail is trusted. |
| A percentage of normal stock | There's no "normal stock" figure to take a percentage of. |

## Cost to Nana if this is wrong

If 10 is too low for fast sellers, they'll show as fine until they're nearly gone. If it's too high for slow ones, the low-stock list gets noisy and people stop reading it. Both are fixed per product without touching any code.
