# ADR-010: Duplicate customers, and where new ids come from

**Status:** accepted
**Files:** `sql/01_diagnosis.sql` (`dq.chk_duplicate_customers`), `sql/02_schema_changes.sql`
**Figures from:** [data_diagnosis.md](../data_diagnosis.md) and the `dq` views in [sql/01_diagnosis.sql](../../sql/01_diagnosis.sql)

## Duplicate customers

**Context:** 533 emails appear on more than one record (1,068 records), mostly the same person twice ("Abena Adjei" and "ABENA ADJEI"). Each record is ranked separately, so a good customer split in two can fall out of the top 100.

**Decision:** flag them, don't merge.

**Why not merge:** merging moves orders and can't be cleanly undone, two people in one household can share an email, and the application may rely on emails not being unique. A merge needs someone to review each pair, plus an application rule to stop new duplicates (recommended in the memo).

**Cost to Nana if wrong:** some customers rank lower than they should. Business-wide totals are unaffected.

## Where new ids come from

**Context:** ids had no default, so the application had to invent them. Two checkouts at once can invent the same id, and one fails.

**Decision:** orders, order lines and log rows now get identity columns that start after the highest existing id. They're safe under any amount of concurrency.

**Alternative rejected:** `max(id) + 1`, which is the same race in a new place.

**Trade-off:** a failed checkout uses up an id, so there can be gaps. Ids are labels, not counts. If an auditor needs unbroken numbering, that should be a separate invoice number.
