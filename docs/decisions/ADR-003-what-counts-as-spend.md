# ADR-003: What counts as a customer's spend

**Status:** accepted
**Files:** `sql/08_monday_report.sql` (`v_order_spend`)
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Context

"Total spent" sounds obvious until you look at the data. Three things had to be settled before any figure in the report means anything.

1. **Which orders count.** Status is one of pending, shipped, completed, cancelled, refunded (after cleanup; before it, fifteen spellings).
2. **Which amount.** Every order has a header total (`orders.total_amount`, written at checkout) and its lines (quantity × price paid). On 1,590 orders they disagree.
3. **Which customers.** 210 orders belong to customer ids that don't exist.

## Decision

- **Completed and shipped orders count.** The money's been taken and the goods have gone. Pending orders aren't paid for yet. Cancelled and refunded orders gave the money back.
- **Spend is the sum of the lines**, not the header total. The lines are what the customer actually chose, at the price on the day. The mismatched header totals aren't random: they're the line total multiplied by exactly 0.75, 0.9, 1.1 or 1.25. That's a calculation going wrong at checkout, not a customer paying something different.
- **Unknown customers are left out of the per-customer report.** There's no one to attribute the spend to. Their ₵665k is listed in the diagnosis so it isn't lost.

## Alternatives I rejected

| Option | Why not |
|---|---|
| Use `total_amount` | It's wrong on ~1,600 orders by a fixed percentage, which points to a bug at checkout. Using it would put that bug into every Monday report. |
| Count pending orders too | Some pending orders never get paid. It would overstate what customers have actually spent. |
| Count refunded orders, subtract later | Adwoa doesn't track refunds separately, so it would just overstate spend. |
| Fix the header totals to match the lines | Possibly right, but the header might be what the customer was charged. That's finance's call, with bank records, not something to change from a database. |

## Cost to Nana if this is wrong

If finance confirms customers were charged the header total, not the lines, then roughly 1,600 orders in the report carry the wrong figure. That's a small share of 159,000 orders, but some customers would move up or down the ranking. Switching is a one-line change in `v_order_spend`. The bigger risk is the opposite one: if the header totals are wrong and the till really charged them, customers were over- or under-charged by those fixed percentages. **That needs checking against payment records, and I'd put it high on the list.**

## What it survives

The definition lives in one view. Every figure in the report (totals, monthly columns, running totals, ranking) is built from it, so they can't drift apart, and if the definition changes it changes everywhere at once.
