# ADR-005: The report's "today", and future-dated orders

**Status:** accepted
**Files:** `sql/00_preflight.sql` (`report_settings`, `report_as_of()`), `sql/08_monday_report.sql`
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Context

"Trailing 12 months" needs an end date. The extract ends on **31 August 2026**: order volume grows every month to 36,357 in August, then there are only 24 orders, scattered as late as August 2027. Those 24 are bad dates, not new business.

## Decision

- A one-row setting holds the report date: 2026-08-31 for this extract. **At go-live, set it to empty** and the report uses the real date.
- The 12 months are the calendar months ending with the report date's month (Sep 2025 to Aug 2026), with the latest month included in full.
- Orders after the report date are left out of the report and listed in the diagnosis.
- **Time zones:** stored times have none, but Accra is on GMT all year, so nothing is ambiguous. New rows are written explicitly in Accra time.

## Alternatives rejected

| Option | Why not |
|---|---|
| Today's date (27 Nov 2026) | Three empty months for every customer, because the extract doesn't cover them |
| The latest order date | That's August 2027, because of the bad dates |
| Guess the real dates | Inventing data |
| Last 12 *complete* months | Reasonable, but drops the current month. An easy switch if Adwoa prefers it. |

## Cost to Nana if wrong

Low. The 24 orders are worth ₵68k across 24 customers. The real risk is forgetting to clear the setting at go-live, which would freeze the report at 31 August. That's why it's in the memo.
