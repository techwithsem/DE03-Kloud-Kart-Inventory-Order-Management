# ADR-001: How orders stop selling stock that isn't there

**Status:** accepted
**Files:** `sql/06_place_order.sql`, `sql/05_stock_movements.sql`

## Context

Twice last month two customers bought the same last unit. The old flow was the usual one: read the stock, decide there's enough, then write the new stock. Between the read and the write there's a gap. Two checkouts land in that gap together, both read "1", both sell. With 4,000 orders a day the gap rarely matters. With 400 orders in ten seconds on one product, which is what marketing expects from a flash sale, it will matter all the time.

`race_test.py` fixes the contract: one function, `place_order`, which must never oversell, never throw an error under contention, say "out of stock" clearly, and write the order and the stock movement together.

## Decision

The stock check and the stock decrement are the same statement:

```sql
UPDATE products
SET stock_quantity = stock_quantity - p_quantity
WHERE product_id = p_product_id
  AND stock_quantity >= p_quantity
RETURNING price, stock_quantity;
```

If that changes one row, the sale went through, and the order, its line and the `sale` movement are written in the same transaction. If it changes nothing, the customer gets "out of stock".

Why this is safe: when two sessions update the same row, PostgreSQL makes the second one wait for the first. Once the first commits, the second re-checks its `WHERE` against the row as it is *now*. Stock is 0, the condition fails, no row is updated. There's no gap to fall into, because there's no separate read.

Underneath that there's a hard rule, `CHECK (stock_quantity >= 0)`, so even a mistake somewhere else can't push stock negative.

The function runs at the default isolation level (READ COMMITTED), takes one row lock, and holds it only for the few milliseconds the inserts take. A `lock_timeout` of 5 seconds and a handler for lock timeouts and deadlocks mean that, even in a situation I haven't foreseen, the customer gets a clear "please try again" and nothing is half-written. That handler never fired in testing.

## Would triggers alone have fixed it?

No, and it's worth being specific about why, because it was a reasonable suggestion.

A trigger runs *inside* each checkout's own write. It can look at the row it's about to write and refuse if the result would be negative. That's exactly what the `CHECK` constraint above does, so a trigger could have stopped stock going below zero. What it couldn't do is give the losing customer a clean answer. The refusal arrives as a database error, the application has to catch it, and `race_test.py` counts an error reaching the caller as a failure. More importantly, if the application still reads stock first and decides later, a trigger doesn't remove that gap. It just turns an oversell into a crash at checkout.

Triggers *are* the right tool for something else here: catching stock changes made outside the proper routines and logging them (see ADR-008). So they're used, just not for the race.

## Alternatives I rejected

| Option | Why not |
|---|---|
| Read with `SELECT ... FOR UPDATE`, then update | Also correct. It takes the same lock, just in two statements, so the lock is held a little longer and there's more code to get wrong. A close second. |
| `SERIALIZABLE` isolation with a retry loop | Correct, but under 400-way contention most attempts fail with a serialization error and retry. The flash sale gets slower exactly when it's busiest, and one bug in the retry loop sends errors to customers. |
| Advisory locks | Works, but it's a second locking system the team has to understand, for no gain over the row lock we get for free. |
| Version number on the row, retry on conflict | Same retry storm as `SERIALIZABLE`. |
| `NOWAIT` / `SKIP LOCKED` | Would tell customers "out of stock" just because someone else was mid-checkout, while stock was still there. That's lying to them. |
| Turn off the wait for the disk on commit | Measured: 10× faster on this laptop. But a power cut could lose the last moments of confirmed, paid orders. Wrong trade for a shop taking payments. |
| Fixing it in the application | Every place that sells would have to get it right. The database is the one place every sale passes through. |

## Evidence

- `race_test.py`, unmodified, passed 10 runs out of 10 (`benchmarks/race_test_runs.txt`).
- Flash sale test: 400 buyers, 50 units, exactly 50 sold, 350 told "out of stock", 0 errors, stock 0.
- Testing also caught a real bug in my first version: a call made straight after the update reset the "did it work?" flag, so refused buyers were treated as winners. The new price constraint stopped those bad orders going in. It's fixed now, and it's a good example of why the database rules are there as well as the function.

## What it survives

- **The flash sale.** 400 buyers on one product queue on one row. Only the 50 winners write anything. Each holds the row until its order is safely on disk, so the queue clears in roughly 50 disk writes. On this laptop a write takes 50 to 380 ms (Docker Desktop's virtual disk), and the whole 400-buyer test took 5 to 9 seconds (once 13). That's still faster than marketing's 400 in 10 seconds. On an ordinary server SSD, at about 1 ms a write, it should clear in well under a second. That last figure is an estimate; I haven't measured it on Kloud Kart's server.
- **Many products at once.** Locks are per product, so a flash sale on one item doesn't slow down orders for anything else.
- **What it doesn't cover:** multi-product baskets. `place_order` takes one product, because that's the contract. A basket version should lock products in a fixed order (by product id) to avoid two baskets deadlocking each other. That's a recommendation, not built.

## Cost to Nana if this is wrong

If the function had a hole, he'd be back to refunds, apologies and bad reviews, but now during a flash sale, at 40 orders a second rather than twice a month. That's why it's tested by the exact test that will be used to judge it, ten times in a row, and why the `CHECK` constraint sits underneath it as a second line of defence.

## What a naive build would have cost later

The read-then-write version passes every test when one person clicks at a time. It fails on the first busy day, which is the day it matters most and the day nobody has time to debug it.
