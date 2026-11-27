# ADR-008: An audit trail an auditor can actually walk

**Status:** accepted
**Files:** `sql/02_schema_changes.sql`, `sql/05_stock_movements.sql`, `sql/11_roles.sql`
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Context

Nana wants proof of what happened: every sale, restock and correction. The old log had no link to orders, no "stock after" figure, no record of who made a change, free-text reasons, notes like "??" and "see WhatsApp msg", and nothing to stop someone changing stock without logging it.

## Decision

- **Every movement says what caused it.** New columns: `order_id` (which order), `stock_after` (the stock straight after the movement) and `recorded_by` (which database user). With `stock_after`, an auditor can check each step without adding up the whole history.
- **Two doors, both logged.** Sales go through `place_order`. Everything else (restock, return, damage, correction, stock take) goes through `record_stock_movement`, which refuses corrections and damage with no note.
- **A trigger catches the back door.** If anyone changes stock any other way, for instance a hand-typed `UPDATE`, the trigger writes it to the log as a correction "changed directly, not through the stock routines". It can't be done silently.
- **No double logging.** The two routines set a flag for their own transaction, so the trigger knows they've already written the row.
- **Nobody edits history.** Duplicate rows are flagged, not deleted. The roles in `11_roles.sql` give no one but the owner the right to update or delete log rows. The checkout application can't touch stock or the log at all except through `place_order`.
- **Reasons are a fixed list:** sale, restock, return, correction, damage, stock_take, opening_balance.

## Alternatives I rejected

| Option | Why not |
|---|---|
| Do all logging in the trigger | The trigger doesn't know which order caused a sale or why someone restocked. The routines do, so they log, and the trigger is the safety net. |
| A trigger that blocks deletes on the log | `race_test.py` cleans up its own test rows by deleting them, so a blocking trigger would break the test. Permissions do the same job for real users without that problem. |
| Separate audit tables per change type | More tables, harder to walk. One log with a reason is what the business already understands. |

## Cost to Nana if this is wrong

The old trail can't be fully trusted (see the diagnosis). Paid orders hold 24,031 more units than the log shows as sold, only 166 products agree exactly, and refunds of 21,531 units left just 1,017 units logged as returned. From here on, each new sale is tied to its order, so that gap can't grow. If someone with owner rights edits the log directly, the trail won't show it. That's an access question for Nana, not something the database can solve on its own.

## What it survives

Flash sales. Every one of the 50 sales in the flash-sale test, all fired at once, left a movement with its order id and the stock after it.
