# Data diagnosis

**Checks:** [sql/01_diagnosis.sql](../sql/01_diagnosis.sql). Each check is a view in the `dq` schema that returns the offending rows. `dq.findings_baseline` keeps the counts from the first run on a fresh load. `dq.findings_before_after` shows them next to today's counts.

## How I went about it

I read `schema.sql` before looking at a single row, and wrote down what it *allows*. There are no foreign keys, so orders can point at customers who don't exist. There are no check constraints, so stock can go negative and status can be anything. Ids have no defaults, emails aren't unique, categories have no protection against loops, and the log has no link to orders. Each of those became a question to ask the data.

Then, for every fault, I asked what it does to a number Nana actually uses (stock on hand, customer spend, the ranking) and ranked them by that. A fault that touches 100,000 rows harmlessly ranks below one that touches 14 and costs a customer.

Money is in Ghana cedis (₵). "Value" is the amount that would be wrong in a report if the fault were left alone, not money already lost.

## Ranked findings

| # | Problem | Rows | Value | What it costs Nana |
|---|---|---|---|---|
| 1 | Negative stock | 14 products | ₵20,628 | Units sold that never existed: refunds, apologies, reviews |
| 2 | Stock trail doesn't match the order book | 3,886 products | | He can't prove what happened to stock, which is the thing he asked for |
| 3 | Stock figure disagrees with its own log | 144 products | ₵3.87m in doubt | Counts he can't trust; the next oversell |
| 4 | Impossible quantities (999, 9,999) | 6 lines | ₵3.07m | One wrong line crowns the wrong "top customer" |
| 5 | Order total disagrees with its lines | 1,590 orders | ₵805k | Possible wrong charges; any report on totals is off |
| 6 | Status spelled 15 ways | 116,394 orders | | A report on "completed" misses 80% of completed orders |
| 7 | Order lines entered twice | 527 lines | ₵882k | Spend and units sold overstated |
| 8 | Lines with no price or price zero | 300 lines | ₵532k | Spend understated; looks like free goods |
| 9 | Lines with no order | 692 lines | ₵826k | Sales nobody can attribute to anyone |
| 10 | Orders for customers who don't exist | 210 orders | ₵665k | Revenue that vanishes from any customer report |
| 11 | Orders dated after the extract ends | 24 orders | ₵68k | Bends "last twelve months" |
| 12 | Stock movements logged twice (proven) | 50 rows | | Trail overstates movements |
| 13 | Corrections with no usable reason | 290 rows | | An auditor can't follow "??" or "see WhatsApp msg" |
| 14 | Category loop and dead end | 3 categories | | A naive rollup hangs forever |
| 15 | Duplicate customers (same email) | 1,068 records | | Good customers split in two and ranked too low |
| 16 | Stock movements for unknown products | 120 rows | | Dead ends in the trail |
| 17 | Products with no category | 37 products | | Invisible in any category view |

## The findings in detail

### 1. Negative stock: 14 products

**Detected by:** `dq.chk_negative_stock`, products where `stock_quantity < 0`. Nothing in the schema prevented it.

**What it means:** 27 units across 14 products were sold that didn't exist. This is the overselling Nana already knows about, sitting in the data. It's ranked first because it's the only fault that has already reached customers.

**Cost:** ₵20,628 of goods promised and not delivered, plus a refund and an apology each time.

**Done:** each product reset to zero through the new logged stock routine, so the trail records when and why. Then a rule was added: stock can never go below zero again.

### 2. The stock trail doesn't describe the same sales as the orders: 3,886 of 4,023 products

**Detected by:** `dq.chk_trail_vs_orders`, comparing units in paid orders (completed, shipped or refunded) with units the log says left as sales, product by product.

**What it means:** across the business it's close (419,370 units ordered, 395,339 logged as sold, a gap of 24,031). Product by product, the two hardly agree at all: only 166 products match exactly (after cleanup), and the correlation between the two is 0.5. Refunded orders account for 21,531 units, but only 1,017 units were ever logged as returned to stock.

**Cost:** this is Nana's fourth wish, "proof of what happened". As things stand, the trail can't prove anything about a specific product, because the log was never tied to orders. I can't tell from the data whether the orders or the log are wrong. Probably both, in different places.

**Done:** from now on every sale writes a movement carrying its order number and the stock straight after it. Old history can't be repaired, only flagged. **This is the finding I'm least able to resolve, and I've said so in the memo.**

### 3. Stock figure disagrees with its own log: 144 products

**Detected by:** `dq.chk_stock_vs_ledger`. For 3,879 products, the stock figure equals the sum of every movement in the log exactly. That's how the two are meant to relate. 144 don't.

| Likely cause | Products | How I know |
|---|---|---|
| The same movement logged twice | 50 | Remove the copy and stock matches exactly |
| A recount noted "recount, not applied" | 39 | Apply it and stock matches exactly |
| No explanation in the data | 55 | |

**Cost:** for the 50, the log is wrong and the stock is right. For the 39, a count was done and never used. For the 55, nobody knows. Those are the products to count first, and the improvement beyond the brief (`v_count_these_first`) lists them, priced.

### 4. Impossible quantities: 6 lines, ₵3.07m

**Detected by:** `dq.chk_implausible_quantities`. The biggest normal line in the data is 10 units. Six say 999 or 9,999.

**How I know they're wrong:** on five of the six, the order's own total pins the real quantity down to a whole number. For example, order 551664 totals ₵1,879.21. Its other line is ₵224.51, which leaves ₵1,654.70, exactly 2 × ₵827.35. The line says 999.

**Cost:** one of these lines made a customer who bought 2 items the business's top spender by ₵570,000. If Adwoa's top-100 drives any decisions (rewards, offers, account managers), they'd be wrong at the very top.

**Done:** five corrected from their order totals, originals kept in `dq.order_item_quantity_fixes`. The sixth couldn't be pinned down and is on a cancelled order. New lines are limited to 100 units, and the report leaves out any order with a line above that.

### 5. Order total disagrees with its lines: 1,590 orders

**Detected by:** `dq.chk_order_total_mismatch`, for orders whose lines are complete and contain no double entries (those are explained by findings 7 and 8).

**What it means:** the mismatches aren't random. The total is the line value × 0.75 (411 orders), × 0.9 (389), × 1.1 (399) or × 1.25 (391). That looks like a discount or surcharge rule misfiring at checkout.

**Cost:** ₵805k of difference. If customers were charged the header total, about 1,600 were over- or under-charged by those percentages. The report uses the lines (ADR-003). **This needs checking against payment records.**

### 6. Status spelled 15 ways: 116,394 orders

**Detected by:** `dq.chk_status_spellings`. "completed", " completed", "COMPLETED", "Completed", "complete", and similar for cancelled, pending, shipped and refunded.

**Cost:** a report filtering on `status = 'completed'` finds 22,091 of the 111,351 completed orders. That's 20%. Spend would be understated by about four-fifths, with no error message to say so. That alone could explain why Nana stopped trusting the report.

**Done:** mapped to five values (originals kept), and a rule now allows only those five.

### 7. Order lines entered twice: 527 lines, ₵882k

**Detected by:** `dq.chk_duplicate_order_lines`, the same product, quantity and price appearing more than once on one order.

**Not everything that looks wrong is wrong:** 613 orders have a repeated line. On 527, the order total matches only once the copy is removed, so those are double entries. On 76, the total matches *with* both lines, so the customer really added the item twice. Those were left alone.

**Done:** the 527 copies moved to `dq.removed_order_items`.

### 8. Lines with no price, or price zero: 300 lines, ₵532k at list price

**Detected by:** `dq.chk_unpriced_order_lines`. 148 lines have no price and 152 have a price of zero.

**How I know the customer paid:** on 285 of them, the order total matches the list price exactly. These lines lost their price; they weren't free.

**Done:** 285 repriced (logged in `dq.order_item_price_fixes`). 15 left as they are, because the total doesn't confirm a price.

### 9. Order lines with no order: 692 lines, ₵826k

**Detected by:** `dq.chk_items_unknown_order`. 692 lines across 689 order numbers that don't exist.

**Cost:** ₵826k of sales with no customer and no date. They can't appear in any report, and they prevent the database from enforcing that every line belongs to an order.

**Done:** moved to `dq.removed_order_items`, not deleted, in case the orders turn up.

### 10. Orders for customers who don't exist: 210 orders, ₵665k

**Detected by:** `dq.chk_orders_unknown_customer`. Customer ids such as 999953, far outside the real range (100001 to 140420).

**Cost:** ₵665k that drops out of any per-customer report without anyone noticing.

**Done:** kept (it may be real money) and flagged. A rule stops any new order being created for a customer who doesn't exist.

### 11. Orders dated after the extract ends: 24 orders, ₵68k

**Detected by:** `dq.chk_orders_after_as_of`. Order volume grows every month up to 36,357 in August 2026, then there are 24 orders scattered as far as August 2027.

**Cost:** small in money, but a report using "the latest date in the data" as today would treat August 2027 as now, and every customer's last twelve months would be mostly empty.

**Done:** kept and flagged. The report uses a fixed "as of" date (ADR-005).

### 12. Stock movements logged twice: 50 proven, out of 519 exact repeats

**Detected by:** `dq.chk_log_duplicates`, the same product, quantity, reason and second.

**Not everything that looks wrong is wrong:** of 519 exact repeats, only 50 are proven doubles, where the stock figure matches the log once the copy is removed. For 437, the stock matches the log *with* the repeat. Those look like two genuine sales of the same item in the same second, which is normal on a busy shop. 32 are unclear.

**Done:** the 50 are flagged `is_duplicate`, never deleted. An audit trail you edit afterwards isn't one.

### 13 to 17, briefly

- **Corrections with no usable reason (290).** Notes like "??", "see WhatsApp msg" and "POS mismatch". An auditor can't follow any of them. New corrections can't be recorded without a note.
- **Category loop and dead end (3).** "Seasonal Promotions" and "Promotions" each named the other as parent. "Clearance" pointed at a category that doesn't exist. A recursive rollup without a guard runs forever on the loop. Fixed, and a trigger now refuses loops.
- **Duplicate customers (533 emails on 1,068 records).** Mostly the same person twice ("Abena Adjei" / "ABENA ADJEI"). It splits their spend and pushes them down the ranking. Flagged, not merged (ADR-010).
- **Movements for unknown products (120 rows, 111 products).** Dead ends in the trail. Kept and flagged. New ones are blocked.
- **Products with no category (37).** They would vanish from the rollup, so they appear as "Uncategorised".

## Looked wrong, but isn't

I checked these and chose not to change them:

| What | Why it's fine |
|---|---|
| ~4,000 lines priced 10% to 50% below today's list price | The price on the day: discounts and old prices. The line is the truth. |
| 90 stock takes with a change of zero | A count that confirmed the stock. |
| 435 duplicate product names | Different ids, prices and categories, so they're variants. |
| Customers in Lagos and Abuja | Real customers in Nigeria. |
| Accra spelled four ways | Untidy, but nothing here depends on it. The report shows it tidied. |
| Order times with no time zone | Accra is on GMT all year with no clock change, so there's nothing ambiguous. |
| 76 orders with a genuinely repeated line, 437 same-second repeat sales | Their own totals and stock figures say they're real. |

## Before and after cleanup

From `dq.findings_before_after` after a full run on a fresh load:

| Problem | Before | After |
|---|---|---|
| Negative stock | 14 | 0 |
| Impossible quantities | 6 | 1 (cancelled order, guarded) |
| Status spellings | 116,394 | 0 |
| Order lines entered twice | 527 | 0 |
| Lines with no or zero price | 300 | 15 |
| Lines with no order | 692 | 0 |
| Category loops and dead ends | 3 | 0 |
| Everything else | unchanged | flagged, with the reason in the decision records |
