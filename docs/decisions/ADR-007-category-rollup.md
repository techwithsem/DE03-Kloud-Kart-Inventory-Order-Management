# ADR-007: Rolling low stock up the category tree

**Status:** accepted
**Files:** `sql/09_category_rollup.sql`, `sql/04_constraints.sql` (loop trigger)
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Context

Categories nest three or four levels deep and marketing keeps adding more. Depth mustn't be hard-coded, and the data contained a loop: two categories each named the other as parent.

## Decision

- A recursive query walks from each category to all its descendants, at any depth. A product counts towards its own category and every one above it.
- One category per product and one parent per category means each product appears once under each ancestor: no double counting. `sql/11_self_checks.sql` verifies this on every build.
- A `CYCLE` guard stops the walk if a loop ever gets in, and a trigger refuses any change that would create one.
- Products with no category show as "Uncategorised".
- "Low" means at or below the product's reorder level (ADR-009). "Out of stock" is shown separately.

## Alternatives rejected

| Option | Why not |
|---|---|
| Join the table to itself four times | Breaks at a fifth level, and the brief rules it out |
| Store each category's full path | Every category move rewrites its subtree. Not worth it for 94 rows. |
| A stored summary | Unnecessary at 15–26 ms, and a live view can't go stale |

## Cost to Nana if wrong

Without the guard, the first loop typed in would hang the page. Without "Uncategorised", 37 products could run out unseen.
