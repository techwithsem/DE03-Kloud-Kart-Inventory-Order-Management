# Memo

**To:** Nana Adjei, Operations, Kloud Kart
**Re:** Overselling, the Monday report, low stock and the stock trail
**Date:** 27 November 2026

## What I built

**Overselling is fixed.** Stock is now checked and taken in one step, so two customers can't both get the last unit: one gets it, the other is told "out of stock" at once. It passed the official test ten times in a row, including 400 customers chasing 50 units. On my laptop all 400 were answered within 6 to 8 seconds, which keeps up with marketing's 400 in 10 seconds. Triggers alone would have stopped stock going below zero, but the second customer would have seen an error rather than "out of stock".

**Adwoa's report takes 6 seconds, not 40 minutes.** It covers every customer: total spent, order count, each of the last 12 months, a running total and the top 100. It shows figures as of its last rebuild, so she rebuilds it on Monday morning (one click, 6 seconds).

**You don't need the bigger server.** The report was slow because of how it was worked out, not the machine.

**Low stock by category** shows every level of the tree in under a second, and new subcategories appear on their own.

**Every stock movement is recorded**: which order caused it, the stock left afterwards and who made it. Even changes typed in by hand are logged.

**Extra: a morning stock check** lists products whose stock doesn't add up, most expensive first. Today that's 94 products and ₵759,000. Counting the top 20 deals with 87% of it.

## What I found

1. **14 products showed stock below zero.** That's the overselling you already know about. I reset them to zero and recorded why.
2. **Order status was typed 15 ways**, so a report on "completed" found only 1 in 5 completed orders.
3. **Six order lines said 999 or 9,999 units.** One made a customer who bought 2 items your top customer by ₵570,000. I corrected five from their order totals.
4. **About 1,600 order totals are off by exactly 10% or 25%**, which looks like a checkout fault.
5. **The old stock history doesn't match the orders**, product by product. From today it will.

## What I recommend

1. Check those ~1,600 order totals against payment records, because some customers may have been charged wrongly.
2. Count the top 20 products on the morning list.
3. At go-live, switch the report date to "today". It's set to 31 August, where your data ends.
4. Stop people signing up twice with one email. 533 emails are on more than one account.

## What I can't stand behind

- Flash-sale speed on your own server. I tested on a laptop, not with real traffic.
- The right stock figure for 55 products. Only a physical count will tell.
- Whether customers paid the order total or the item prices on those ~1,600 orders. I used item prices; finance should confirm.
- Stock history before today.
