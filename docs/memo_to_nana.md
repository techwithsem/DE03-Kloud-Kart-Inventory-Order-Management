# Memo

**To:** Nana Adjei, Operations, Kloud Kart
**Re:** Overselling, the Monday report, low stock, and the stock trail
**Date:** 27 November 2026

## What I built

**Overselling is fixed.** The system now checks stock and takes it in one step, so two customers can no longer both get the last unit. One gets it, the other is told "out of stock" straight away. I tested it with the official test ten times in a row, including 400 customers chasing 50 units at once: exactly 50 sold, every time, with no errors. The cost: during a flash sale buyers queue briefly for the same product. On my laptop 400 buyers were usually all answered within 6 to 8 seconds, which keeps up with the 400 in 10 seconds marketing expects. If flash sales grow far beyond that, I'd want to test on your actual server.

The idea of using triggers would have stopped stock going below zero, but the second customer would have seen an error rather than a clear "out of stock". The real gap, checking stock and taking it as two separate steps, would still have been there.

**Adwoa's report takes 6 seconds, not 40 minutes.** Once it's built, opening it is instant. It covers every customer: total spent, number of orders, each of the last 12 months, a running total, and the top 100. The figures are as of the last time it was rebuilt, so she should rebuild it on Monday morning before reading it. That takes one click and 6 seconds.

**You don't need the bigger server.** The report was slow because of the way it was worked out, not the machine. The same laptop went from hours to seconds.

**Low stock by category** shows every level of the category tree (Electronics, then Phones, then Accessories, and so on) in a fraction of a second. New subcategories appear on their own.

**Every stock movement is now recorded**, with the order behind it, the stock left afterwards and who made it. Even a change typed in by hand is caught and logged.

**Extra: a morning stock check.** Every morning it lists products whose stock doesn't add up, priced, most expensive first. Today that's 94 products and ₵759,000. Counting the top 20 deals with 87% of it.

## What I found in the data

1. **14 products showed less than zero in stock.** That's the overselling you already know about. I reset them to zero and recorded why.
2. **The order status was typed 15 different ways.** A report looking for "completed" was finding only 1 in 5 completed orders. That may be why the old figures never felt right.
3. **Six order lines claimed 999 or 9,999 units.** One made a customer who bought 2 items look like your best customer by ₵570,000. I corrected five from their own order totals.
4. **About 1,600 orders have a total that's off by exactly 10% or 25%**, up or down. It looks like a checkout fault.
5. **The old stock history doesn't match the orders**, product by product. I can't prove what happened to stock before today. From today, I can.

## What I recommend next

1. **Check those ~1,600 order totals against bank and payment records.** Some customers may have been over- or under-charged.
2. **Count the top 20 products on the morning list**, and record what you find.
3. **When this goes live, switch the report date to "today"** (it's set to 31 August, where your data ends).
4. **Stop customers signing up twice with the same email.** 533 emails appear on more than one account, which splits their spending.

## What I can't stand behind

- **Flash-sale speed on your server.** I tested on a laptop, never on your server or with real traffic.
- **Which stock figure is right for 55 products.** The records disagree and nothing explains it. Only a physical count will tell.
- **Whether customers paid the order total or the item prices** on those ~1,600 orders. I used the item prices. Finance should confirm.
- **Anything before today in the stock history.** I've flagged what I could, but it can't be fully trusted.
