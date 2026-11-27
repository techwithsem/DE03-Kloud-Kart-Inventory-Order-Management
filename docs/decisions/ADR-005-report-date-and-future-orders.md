# ADR-005: What "today" means for the report, and the orders dated in the future

**Status:** accepted
**Files:** `sql/00_preflight.sql` (`report_settings`, `report_as_of()`), `sql/08_monday_report.sql`

## Context

"Trailing twelve months" needs an end date. The obvious one is today, but the extract stops on **31 August 2026**. Order volume grows steadily every month to 36,000 in August, then drops to a handful. After 31 August there are only 24 orders, scattered as far as August 2027. Those 24 aren't a trickle of new business: they're dates that were typed or stored wrongly.

## Decision

- A one-row settings table holds the report date. For this extract it's set to **2026-08-31**. On the live server it should be set to empty, and the report then uses the real current date automatically.
- The twelve months are the twelve calendar months ending with the report date's month (September 2025 to August 2026 here), including the latest month in full.
- Orders dated after the report date are left out of the report and listed in the diagnosis. Their real dates can't be worked out from the data.

## Alternatives I rejected

| Option | Why not |
|---|---|
| Use today's date (27 Nov 2026) | Three of the twelve months would be empty for every customer, because the extract doesn't cover them. The report would look broken. |
| Use the latest order date as "today" | That's August 2027, because of the bad dates. It would make the report shift around every time a bad date gets in. |
| "Fix" the 24 dates (e.g. assume the year is wrong) | Some might be 2025 typed as 2027, some something else entirely. Guessing a date is inventing data. |
| Last 12 *complete* months | Reasonable, but Adwoa runs this on Mondays and would lose the current month to date. Easy to switch if she prefers. |

## Cost to Nana if this is wrong

Low. The 24 orders are worth ₵68k between them, spread over 24 customers. If the setting is left at 2026-08-31 on the live server, the report would quietly freeze at that date. That's the real risk, which is why the memo tells him to clear it at go-live.

## Also decided: time zones

Order times are stored without a time zone. Accra is on GMT all year with no daylight saving, so the stored times are Accra time and there's no ambiguity. New rows are written explicitly in Accra time, so a server set to a different zone can't shift them. I didn't treat the missing time zone as a fault worth changing the column for.
