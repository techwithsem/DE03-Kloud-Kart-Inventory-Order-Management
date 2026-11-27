# ADR-007: Rolling low stock up the category tree

**Status:** accepted
**Files:** `sql/09_category_rollup.sql`, `sql/04_constraints.sql` (loop trigger)
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Context

Categories nest three or four levels today (Electronics > Phones > Phone Accessories > Cases) and marketing keeps adding more. Nana wants to see low stock for "Electronics" as a whole, at a glance, in a couple of seconds. The brief says not to hard-code the depth. The data also contained a loop: two categories each named the other as parent.

## Decision

- A recursive query walks the tree from every category down to all of its descendants, at whatever depth. Each product counts towards its own category and every category above it.
- Because each product has one category and each category has one parent, each product appears once under each ancestor, so nothing is double counted.
- The query carries a cycle guard (PostgreSQL's `CYCLE` clause). If a loop ever got in, the walk would stop instead of running forever.
- A trigger on `categories` refuses any change that would create a loop, so the guard should never be needed.
- Products with no category show up as their own line, "Uncategorised", instead of quietly vanishing.
- Low stock = stock at or below the product's reorder level (ADR-009). Out of stock is shown separately.

## Alternatives I rejected

| Option | Why not |
|---|---|
| Join the table to itself four times | Breaks the day marketing adds a fifth level. The brief rules it out. |
| Store the full path on each category ("101/102/115") | Fast, but every move of a category has to rewrite its whole subtree. More to maintain, for a tree of 94 rows. |
| A stored summary table | Not needed. The live query takes milliseconds (see the measurement report), and a live view can't go stale. |

## Cost to Nana if this is wrong

If the guard were missing, the first loop someone typed into the category screen would hang the low-stock page. If uncategorised products weren't shown, 37 products could run out without appearing anywhere.

## What it survives

Any depth, any number of new categories, and a loop typed in by mistake: the trigger blocks it, and if it got in some other way the guard still stops the walk.
