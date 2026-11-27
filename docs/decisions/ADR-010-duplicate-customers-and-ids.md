# ADR-010: Duplicate customers, and where new ids come from

**Status:** accepted
**Files:** `sql/01_diagnosis.sql` (`dq.chk_duplicate_customers`), `sql/02_schema_changes.sql`

## Duplicate customers

### Context

533 email addresses appear on more than one customer record (1,068 records in all). Most look like the same person signing up twice: "Abena Adjei" and "ABENA ADJEI", same email. Each record gets ranked separately in the Monday report, so a good customer split in two can drop out of the top 100.

### Decision

Flagged, not merged. The list is in `dq.chk_duplicate_customers`.

### Why not merge

Merging moves orders between records and can't be cleanly undone. Two people in one household can share an email. And the email column has never been unique, so the application may rely on that. A merge needs someone who can look at each pair, and a rule in the application to stop new duplicates. That's a recommendation in the memo.

### Cost to Nana if this is wrong

Some customers are ranked lower than they should be. The report's totals for the business as a whole are unaffected.

## Where new ids come from

### Context

Every table's id was a plain number with no default, so the application had to invent the next id itself. Two checkouts at the same moment can invent the same one, and one of them fails.

### Decision

Orders, order lines and log rows now get their ids from the database, starting after the highest id already used. That's a PostgreSQL identity column, which is safe under any amount of concurrency.

### Alternative rejected

`max(id) + 1` in the order function. That's the same race we're trying to remove, in a new place.

### Trade-off

Ids can now have gaps: a failed checkout uses up a number. Ids are labels, not a count, so nothing should depend on them being consecutive. If an auditor expects unbroken invoice numbers, that should be a separate invoice number, not the order id.
