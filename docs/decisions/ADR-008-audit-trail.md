# ADR-008: An audit trail an auditor can walk

**Status:** accepted
**Files:** `sql/02_schema_changes.sql`, `sql/05_stock_movements.sql`, `sql/11_roles.sql`
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Context

The old log had no link to orders, no "stock after", no record of who made a change, notes like "??", and nothing stopping stock changing without a log entry.

## Decision

- **New columns:** `order_id`, `stock_after` and `recorded_by`. With `stock_after`, each step can be checked without adding up the whole history.
- **Two doors, both logged:** sales go through `place_order`; restocks, returns, damage, corrections and stock takes go through `record_stock_movement`, which refuses a correction or damage entry without a note.
- **A trigger covers the back door:** any other change to stock (such as a hand-typed `UPDATE`) is logged as "changed directly, not through the stock routines".
- **No double logging:** the routines set a flag for their own transaction, so the trigger skips what they've already logged.
- **Nobody edits history:** duplicates are flagged, not deleted, and the roles give no one except the owner the right to update or delete log rows. The checkout app can touch stock only through `place_order`.
- **Reasons are a fixed list:** sale, restock, return, correction, damage, stock_take, opening_balance.

## Alternatives rejected

| Option | Why not |
|---|---|
| Log everything from the trigger | The trigger can't know which order or why |
| A trigger that blocks deletes | `race_test.py` deletes its own test rows, so it would break the test. Permissions do the job instead. |
| Separate audit tables per change type | More to walk through, for no benefit |

## Cost to Nana if wrong

The old trail can't be trusted: paid orders hold 24,031 more units than were logged as sold, only 166 products agree exactly, and refunds of 21,531 units left just 1,017 logged as returned. From now on every sale carries its order, so that gap can't grow. Anyone with owner rights could still edit the log; that's an access policy for Nana to set.

## What it survives

Flash sales: every one of the 50 flash-sale sales left a movement with its order and stock after.
