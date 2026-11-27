# Data diagnosis

**Checks:** [sql/01_diagnosis.sql](../sql/01_diagnosis.sql). Each check is a view in the `dq` schema that returns the offending rows. `dq.findings_baseline` keeps the first-run counts on a fresh load, and `dq.findings_before_after` shows them next to today's.

**Method.** I read `schema.sql` before any data and listed what it allows: no foreign keys, no checks, free-text status, no id defaults, non-unique emails, nothing stopping category loops, and no link from the stock log to orders. Each became a check. I ranked the faults by what they do to figures Nana uses (stock, spend, ranking), not by row count. "Value" is the amount a report would get wrong, in cedis.

## Ranked findings

| # | Problem | Rows | Value | Cost to Nana | Action |
|---|---|---|---|---|---|
| 1 | Negative stock | 14 products | ₵20,628 | 27 units sold that didn't exist | Reset to 0 via logged correction; stock can't go below 0 again |
| 2 | Stock trail doesn't match orders | 3,886 products | | Can't prove what happened to stock | Every new sale is logged with its order; old history only flagged |
| 3 | Stock disagrees with its own log | 144 products | ₵3.87m in doubt | Counts he can't trust | Priced count list (the improvement) |
| 4 | Impossible quantities (999, 9,999) | 6 lines | ₵3.07m | Wrong "top customer" | 5 fixed from order totals; new lines capped at 100 |
| 5 | Order total ≠ its lines | 1,590 orders | ₵805k | Possible wrong charges | Report uses lines; check against payments |
| 6 | Status spelled 15 ways | 116,394 orders | | "completed" finds 1 in 5 | Mapped to 5 values, enforced |
| 7 | Lines entered twice | 527 lines | ₵882k | Spend overstated | Copies moved to quarantine |
| 8 | No price or zero price | 300 lines | ₵532k | Spend understated | 285 repriced; 15 flagged |
| 9 | Lines with no order | 692 lines | ₵826k | Sales owned by nobody | Moved to quarantine |
| 10 | Orders for unknown customers | 210 orders | ₵665k | Drops out of customer reports | Kept, flagged, blocked for new orders |
| 11 | Orders dated after the extract | 24 orders | ₵68k | Bends "last 12 months" | Kept, flagged; report uses a fixed date |
| 12 | Movements logged twice (proven) | 50 rows | | Trail overstates movements | Flagged, never deleted |
| 13 | Corrections with no usable reason | 290 rows | | Auditor can't follow them | New corrections need a note |
| 14 | Category loop and dead end | 3 categories | | Naive rollup hangs | Fixed; loops now refused |
| 15 | Duplicate customers (same email) | 1,068 records | | Spend split, rank too low | Flagged, not merged |
| 16 | Movements for unknown products | 120 rows | | Dead ends in the trail | Flagged; new ones blocked |
| 17 | Products with no category | 37 | | Invisible in category views | Shown as "Uncategorised" |

## Evidence for the main findings

**1. Negative stock** (`dq.chk_negative_stock`). Nothing stopped `stock_quantity < 0`. This is the overselling Nana already knows about, and it ranks first because it has already reached customers.

**2. Trail vs orders** (`dq.chk_trail_vs_orders`). Across the business the two are close: 419,370 units in paid orders against 395,339 logged as sold. Product by product they barely agree: after cleanup only 166 products match exactly, the correlation is 0.5, and refunds of 21,531 units left just 1,017 logged as returned. I can't tell which side is wrong. **This is the finding I'm least able to resolve.**

**3. Stock vs its log** (`dq.chk_stock_vs_ledger`). For 3,879 products, stock equals the sum of the log exactly, so that's how the two are meant to relate. Of the 144 that don't, 50 are explained by a movement logged twice, 39 by a recount marked "recount, not applied", and 55 by nothing in the data.

**4. Impossible quantities** (`dq.chk_implausible_quantities`). The largest normal line is 10 units. On five of the six bad lines, the order total pins down the real quantity. For example, order 551664 totals ₵1,879.21; the other line is ₵224.51, which leaves ₵1,654.70 = 2 × ₵827.35, yet the line says 999. That line made its customer the top spender by ₵570,000. The sixth line is on a cancelled order and can't be pinned down.

**5. Total vs lines** (`dq.chk_order_total_mismatch`). The total is the line value × 0.75 (411 orders), × 0.9 (389), × 1.1 (399) or × 1.25 (391). That's a pricing rule misfiring at checkout, not noise.

**6. Status** (`dq.chk_status_spellings`). `status = 'completed'` matches 22,091 of 111,351 completed orders (20%).

**7–8. Duplicate and unpriced lines.** I only fixed what the order's own total confirms. On 527 orders the total matches only once the copy is removed; on 76 others it matches *with* both lines, so those are real and stay. On 285 unpriced lines the total matches the list price.

**12. Repeated movements** (`dq.chk_log_duplicates`). There are 519 exact repeats (same product, quantity, reason and second). Only 50 are proven doubles, where stock matches the log once the copy is removed. For 437, stock matches *with* the repeat, so they're most likely two real sales in the same second. 32 are unclear.

## Looked wrong, but isn't

| What | Why it's fine |
|---|---|
| ~4,000 lines priced 10–50% below today's list price | The price on the day the order was placed |
| 90 stock takes with zero change | A count that confirmed the stock |
| 435 duplicate product names | Different ids, prices and categories: they're variants |
| Customers in Lagos and Abuja | Real customers in Nigeria |
| Accra spelled four ways | Untidy, but nothing depends on it |
| Times stored without a time zone | Accra is on GMT all year, so nothing is ambiguous |
| 76 repeated order lines, 437 same-second repeat sales | Their own totals and stock figures confirm them |

## Before and after cleanup

From `dq.findings_before_after`: negative stock 14 → 0; impossible quantities 6 → 1 (on a cancelled order, and the report excludes it); status spellings 116,394 → 0; double entries 527 → 0; unpriced lines 300 → 15; lines with no order 692 → 0; category loops and dead ends 3 → 0. Everything else is unchanged and flagged, with the reasons in the [decision records](decisions/).
