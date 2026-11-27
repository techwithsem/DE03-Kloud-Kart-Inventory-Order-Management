# ADR-006: What gets fixed, what gets flagged, and what's left alone

**Status:** accepted
**Files:** `sql/03_cleanup.sql`, `sql/04_constraints.sql`
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Context

The brief warns that the data has undocumented problems and that "not everything that looks wrong is wrong". Nana's team has to live with whatever I change, and nobody is around to ask.

## Decision

One rule for every fix: **change a row only when the data itself proves what the right value is, and keep a copy of the original.** Everything else gets flagged and stays as it was.

| Problem | What I did | Why I'm confident |
|---|---|---|
| Status spelled 15 ways | Mapped to 5 values. Originals kept in `dq.order_status_original` | `complete`/`completed` and `canceled`/`cancelled` can't mean different things. |
| Order lines entered twice | Removed the copy on 527 orders. Copies kept in `dq.removed_order_items` | On those 527, the order's own total matches only once the copy is removed. On 76 other orders it matches *with* both lines, so those are real and stay. |
| Lines with no price or zero price | List price restored on 285 lines. Fixes logged in `dq.order_item_price_fixes` | The order total matches the list price exactly. The 15 where it doesn't stay unpriced and flagged. |
| Lines with no order | 692 lines moved to quarantine | No customer, no date. They can't go in any report and they block the link between lines and orders. Kept in case the orders turn up. |
| Category loop and dead end | Promotions made top-level, Clearance made top-level. Logged in `dq.category_fixes` | Two categories each claimed the other as parent. Promotions is the broader name. |
| Impossible quantities (999, 9,999) | Corrected on 5 of 6 lines. Originals in `dq.order_item_quantity_fixes` | The order total pins the real quantity down to a whole number. |
| Stock movements logged twice | 50 proven doubles flagged with `is_duplicate`, not deleted | Stock matches the log only without the copy. The other 469 exact repeats agree with stock as they are, so most look like real same-second sales. |
| Negative stock | Reset to zero through the logged stock routine (ADR-004) | Negative stock can't physically exist. |

Then rules go on the tables so the faults can't come back: allowed statuses, real customers and products, positive quantities and prices, no stock below zero, no category loops. Where old rows break a rule and I deliberately left them, the rule is added as `NOT VALID`. It checks every new or changed row but doesn't fail on history.

## Left alone, on purpose

These look wrong but aren't, or aren't mine to change:

- **Line prices below today's list price** (about 4,000 lines, 10% to 50% lower). That's the price on the day: discounts, old prices. The line is right.
- **Stock takes with a change of zero** (90). A count that confirmed the stock. That's what a stock take should look like.
- **Duplicate product names** (435). Different ids, prices and categories. They're variants, not copies.
- **Customers in Lagos and Abuja.** Real customers in Nigeria, not bad data.
- **City spelled four ways for Accra.** Untidy, but nothing in this brief depends on it. The report shows cities tidied up without changing the stored value.
- **Header totals that disagree with lines.** Possibly what customers were charged. That needs checking against payments (ADR-003).
- **Orders for unknown customers and orders with future dates.** Real money, unknown owner or date. Flagged and kept out of reports.

## Alternatives I rejected

- **Delete everything suspicious.** It would give the cleanest-looking database and the least trustworthy one. It would also throw away ₵826k of order lines and ₵665k of orders that may be perfectly real.
- **Fix nothing, just document.** Then the report and the rollup are built on 15 status spellings and double entries, and the "never oversell" rule can't be switched on.

## Cost to Nana if this is wrong

Every change is reversible from the `dq` tables. If one of the rules turns out to be wrong (say a "double entry" really was two of the same item), the original row is there to put back.
