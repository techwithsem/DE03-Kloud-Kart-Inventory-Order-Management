"""load test: 4,000 people trying to order at the same time.

a real shop doesn't give every visitor their own database connection. the website keeps a
small pool and hands each order to the next free connection. this test does the same:
100 pooled connections work through 4,000 buy attempts, all released at once.

  scenario a: everyone chases one product with 50 units.
  scenario b: the same 4,000 attempts spread across 100 products with 30 units each.

after each scenario it checks: nothing oversold, stock never below zero, exactly one order
and one stock movement per sale, and no errors. it cleans up its own products afterwards.

run it with:  python main.py load
"""

import os
import random
import statistics
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import psycopg2

DSN = os.environ.get("DATABASE_URL")
FIXTURE_PREFIX = "RACE TEST FIXTURE LOAD"
ATTEMPTS = 4000
POOL_SIZE = 100


# opens one connection per pool slot, the way a web app's connection pool would.
def open_pool():
    pool = []
    for _ in range(POOL_SIZE):
        conn = psycopg2.connect(DSN)
        conn.autocommit = True
        pool.append(conn)
    return pool


# creates the test products and returns their ids.
def make_products(count, stock):
    with psycopg2.connect(DSN) as conn, conn.cursor() as cur:
        cur.execute("SELECT coalesce(max(product_id), 0) + 5000 FROM products")
        first_id = cur.fetchone()[0]
        ids = list(range(first_id, first_id + count))
        for pid in ids:
            cur.execute(
                "INSERT INTO products (product_id, product_name, category_id, price,"
                " stock_quantity, created_at) VALUES (%s, %s, NULL, 100.00, %s, now())",
                (pid, f"{FIXTURE_PREFIX} {pid}", stock),
            )
    return ids


# removes every test product with its orders and stock movements, in the same order
# race_test.py uses.
def cleanup():
    with psycopg2.connect(DSN) as conn, conn.cursor() as cur:
        cur.execute("SELECT product_id FROM products WHERE product_name LIKE %s",
                    (FIXTURE_PREFIX + "%",))
        pids = [r[0] for r in cur.fetchall()]
        if not pids:
            return
        cur.execute("SELECT DISTINCT order_id FROM order_items WHERE product_id = ANY(%s)", (pids,))
        oids = [r[0] for r in cur.fetchall()]
        cur.execute("DELETE FROM order_items WHERE product_id = ANY(%s)", (pids,))
        if oids:
            cur.execute("DELETE FROM order_items WHERE order_id = ANY(%s)", (oids,))
            cur.execute("DELETE FROM orders WHERE order_id = ANY(%s)", (oids,))
        cur.execute("DELETE FROM inventory_log WHERE product_id = ANY(%s)", (pids,))
        cur.execute("DELETE FROM products WHERE product_id = ANY(%s)", (pids,))


# fires every attempt through the pool, all released together, and records each result.
def fire(pool, customer_id, product_ids):
    free = list(pool)
    lock = threading.Lock()
    start = threading.Event()
    results = []

    def attempt(product_id):
        start.wait()
        with lock:
            conn = free.pop()
        t0 = time.perf_counter()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT success, order_id, message FROM place_order(%s, %s, 1)",
                            (customer_id, product_id))
                success, order_id, message = cur.fetchone()
            outcome = ("sold" if success
                       else "out of stock" if "out of stock" in (message or "").lower()
                       else "busy")
            error = ""
        except Exception as exc:
            outcome, error = "error", f"{type(exc).__name__}: {exc}".strip()
        elapsed = time.perf_counter() - t0
        with lock:
            free.append(conn)
            results.append((product_id, outcome, elapsed, error))

    with ThreadPoolExecutor(max_workers=POOL_SIZE) as executor:
        futures = [executor.submit(attempt, pid) for pid in product_ids]
        time.sleep(0.5)
        wall_start = time.perf_counter()
        start.set()
        for f in futures:
            f.result()
        wall = time.perf_counter() - wall_start
    return results, wall


# checks the database afterwards and prints a short report. returns a list of problems.
def report(title, results, wall, product_ids, units_each):
    counts = {k: sum(1 for r in results if r[1] == k) for k in ("sold", "out of stock", "busy", "error")}
    times = sorted(r[2] * 1000 for r in results)
    total_units = units_each * len(product_ids)

    with psycopg2.connect(DSN) as conn, conn.cursor() as cur:
        cur.execute("SELECT sum(stock_quantity), min(stock_quantity) FROM products WHERE product_id = ANY(%s)",
                    (product_ids,))
        stock_left, lowest_stock = cur.fetchone()
        cur.execute("SELECT count(DISTINCT order_id) FROM order_items WHERE product_id = ANY(%s)", (product_ids,))
        orders = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM inventory_log WHERE product_id = ANY(%s) AND reason = 'sale'",
                    (product_ids,))
        sale_rows = cur.fetchone()[0]

    problems = []
    if counts["sold"] + stock_left != total_units:
        problems.append(f"sold {counts['sold']} + left {stock_left} does not equal the {total_units} units stocked")
    if lowest_stock < 0:
        problems.append(f"stock went below zero ({lowest_stock})")
    if orders != counts["sold"]:
        problems.append(f"{orders} orders for {counts['sold']} sales")
    if sale_rows != counts["sold"]:
        problems.append(f"{sale_rows} stock movements for {counts['sold']} sales")
    if counts["error"]:
        problems.append(f"{counts['error']} attempts raised an error, e.g. {next(r[3] for r in results if r[3])}")
    if counts["sold"] != min(total_units, ATTEMPTS):
        problems.append(f"only {counts['sold']} sold while {total_units} units were available")

    print(f"\n{title}")
    print(f"  attempts            {len(results)} through {POOL_SIZE} pooled connections")
    print(f"  units available     {total_units} ({len(product_ids)} product(s) x {units_each})")
    print(f"  sold                {counts['sold']}")
    print(f"  out of stock        {counts['out of stock']}")
    print(f"  busy, try again     {counts['busy']}")
    print(f"  errors              {counts['error']}")
    print(f"  stock left          {stock_left} (lowest on any product: {lowest_stock})")
    print(f"  orders / movements  {orders} / {sale_rows}")
    print(f"  wall clock          {wall:.2f} s  ({len(results) / wall:.0f} attempts a second)")
    print(f"  per attempt         median {statistics.median(times):.0f} ms, "
          f"95th percentile {times[int(len(times) * 0.95) - 1]:.0f} ms, slowest {times[-1]:.0f} ms")
    print("  result              " + ("ok" if not problems else "FAILED: " + "; ".join(problems)))
    return problems


# runs both scenarios and exits non-zero if either one found a problem.
def main():
    if not DSN:
        sys.exit("DATABASE_URL is not set. run this through: python main.py load")

    with psycopg2.connect(DSN) as conn, conn.cursor() as cur:
        cur.execute("SELECT min(customer_id) FROM customers")
        customer_id = cur.fetchone()[0]

    print(f"load test: {ATTEMPTS} buy attempts at once, through {POOL_SIZE} pooled connections")
    cleanup()
    pool = open_pool()
    problems = []
    try:
        hot = make_products(1, 50)
        results, wall = fire(pool, customer_id, hot * ATTEMPTS)
        problems += report("scenario a: one hot product, 50 units", results, wall, hot, 50)

        spread = make_products(100, 30)
        attempts = [spread[i % len(spread)] for i in range(ATTEMPTS)]
        random.shuffle(attempts)
        results, wall = fire(pool, customer_id, attempts)
        problems += report("scenario b: 100 products, 30 units each", results, wall, spread, 30)
    finally:
        for conn in pool:
            conn.close()
        cleanup()

    print("\nPASSED: nothing oversold, no errors." if not problems else f"\nFAILED: {len(problems)} problem(s).")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
