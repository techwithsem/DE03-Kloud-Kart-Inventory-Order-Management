# ADR-001: Stopping overselling

**Status:** accepted
**Files:** `sql/06_place_order.sql`, `sql/05_stock_movements.sql`
**Figures from:** [measurement_report.md](../measurement_report.md) and the raw output in [benchmarks/](../../benchmarks/)

## Context

The old flow read the stock, decided, then wrote. Two checkouts in that gap both read "1" and both sold. A flash sale (400 orders in 10 seconds on one product) makes that gap the normal case. `race_test.py` fixes the contract: `place_order` must never oversell, never raise an error under contention, say "out of stock" clearly, and write the order and its stock movement together.

## Decision

The check and the decrement are one statement:

```sql
UPDATE products
SET stock_quantity = stock_quantity - p_quantity
WHERE product_id = p_product_id
  AND stock_quantity >= p_quantity
RETURNING price, stock_quantity;
```

If one row is updated, the order, its line and the sale movement are written in the same transaction. If none is, the customer is told "out of stock". When two sessions update the same row, PostgreSQL makes the second wait, then re-checks its `WHERE` against the committed row. Stock is now 0, so it updates nothing. There's no separate read, so there's no gap.

Safety nets: `CHECK (stock_quantity >= 0)`; a 5 s `lock_timeout`; and a handler that turns a lock timeout or deadlock into a clear "please try again" with nothing half-written. The handler never fired in testing.

## Would triggers alone have fixed it?

No. A trigger could refuse a write that takes stock below zero, as the `CHECK` does. But the losing customer would get a database error rather than "out of stock", which fails the contract. And if the application still reads before it writes, the gap remains; it just turns an oversell into a failed checkout. Triggers are used here for the audit trail (ADR-008), where they are the right tool.

## Alternatives rejected

| Option | Why not |
|---|---|
| `SELECT ... FOR UPDATE`, then update | Correct, but two statements and a longer lock. The close runner-up. |
| `SERIALIZABLE` with a retry loop | Under 400-way contention most attempts fail and retry, so it's slowest exactly when busiest, and a retry bug leaks errors to customers |
| Advisory locks | A second locking system to maintain, for no gain |
| Version column, retry on conflict | The same retry storm |
| `NOWAIT` / `SKIP LOCKED` | Says "out of stock" while stock still exists |
| Don't wait for the disk on commit | Measured: 50 ms down to 5 ms per order on this laptop (measurement report, section 3). But a power cut could lose confirmed, paid orders. |
| Fix it in the application | Every selling path would have to get it right. The database is the one place all sales pass through. |

## Evidence

- `race_test.py`, unmodified: 10 of 10 runs passed. In the flash-sale test, 50 sold, 350 told "out of stock", 0 errors, stock 0.
- Testing caught a bug in my first version: a call straight after the update reset PL/pgSQL's `FOUND` flag, so refused buyers were treated as winners. The new price constraint blocked those bad orders. It's fixed, and it shows why the database rules sit underneath the function.
- `sql/12_self_checks.sql` re-tests the last-unit case on every build.

## What it survives

- **The flash sale.** Only the 50 winners write anything, and each holds the row until its order is on disk. On this laptop (disk writes take 50–380 ms) the 400-buyer test took 5–9 s, once 13 s, which keeps up with 400 in 10 seconds. On a normal server SSD it should take well under a second. That's an estimate; I haven't measured it there.
- **Many products at once.** Locks are per product.
- **Not covered:** multi-product baskets. The contract is one product per order. A basket version should lock products in id order to avoid deadlocks.

## Cost to Nana if wrong

Refunds, apologies and bad reviews again, but at flash-sale speed. That's why it was tested ten times with the real test, with the `CHECK` constraint underneath as a second defence.

## What a naive build would have cost

Read-then-write passes every test with one user and fails on the first busy day: the day it matters most.
