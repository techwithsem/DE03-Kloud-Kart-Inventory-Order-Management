# ADR-003: What counts as a customer's spend

**Status:** accepted
**Files:** `sql/08_monday_report.sql` (`v_order_spend`)
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Context

Three questions had to be settled before "total spent" meant anything: which orders count, which amount to use (the header `total_amount` disagrees with the lines on 1,590 orders), and what to do with 210 orders whose customers don't exist.

## Decision

- **Completed and shipped orders count.** Pending orders aren't paid yet; cancelled and refunded orders gave the money back.
- **Spend is the sum of the lines** (quantity × price paid), not the header. The mismatched headers are the line total × exactly 0.75, 0.9, 1.1 or 1.25: a checkout calculation fault, not what the customer chose.
- **Orders with a line over 100 units are excluded.** Five were corrected; the one left is on a cancelled order.
- **Unknown customers are left out** of the per-customer report. Their ₵665k is listed in the diagnosis.

## Alternatives rejected

| Option | Why not |
|---|---|
| Use `total_amount` | It's wrong by a fixed percentage on 1,590 orders |
| Count pending orders | Some are never paid |
| Count refunds and subtract later | Adwoa doesn't track refunds separately |
| Rewrite header totals to match the lines | The header may be what was actually charged. That's for finance to decide from payment records. |

## Cost to Nana if wrong

If customers were actually charged the header totals, about 1,600 orders carry the wrong figure and some rankings shift. Switching is a one-line change in `v_order_spend`. The bigger worry is that those customers were charged wrongly at all. **Check against payment records.**

## What it survives

The definition lives in one view, so every figure (totals, months, running totals, rank) changes together. `sql/12_self_checks.sql` re-derives the total from the raw tables on every build.
