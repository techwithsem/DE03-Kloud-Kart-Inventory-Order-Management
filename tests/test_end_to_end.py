"""end-to-end tests: the report refresh, the low-stock and count lists, the build's own
self checks, and the supplied race test, run unmodified."""

import os
import subprocess

import pytest

import main

pytestmark = pytest.mark.database


# adds a completed order in the report window, refreshes the report, and checks the
# customer's total went up by exactly that order. the transaction is rolled back after.
def test_a_refresh_picks_up_a_new_order(cur, customer_id, make_product):
    product_id = make_product(stock=5, price=40.00)
    cur.execute("SELECT total_spent FROM mv_customer_spend_report WHERE customer_id = %s", (customer_id,))
    before = cur.fetchone()[0]

    cur.execute("INSERT INTO orders (customer_id, order_date, status, total_amount)"
                " VALUES (%s, (SELECT report_as_of()) - 1, 'completed', 80) RETURNING order_id", (customer_id,))
    order_id = cur.fetchone()[0]
    cur.execute("INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (%s, %s, 2, 40)",
                (order_id, product_id))
    cur.execute("SELECT refresh_monday_report()")

    cur.execute("SELECT total_spent FROM mv_customer_spend_report WHERE customer_id = %s", (customer_id,))
    assert cur.fetchone()[0] - before == 80


# checks that a cancelled order doesn't count as spend.
def test_a_cancelled_order_is_not_counted_as_spend(cur, customer_id, make_product):
    product_id = make_product(stock=5, price=40.00)
    cur.execute("SELECT total_spent FROM mv_customer_spend_report WHERE customer_id = %s", (customer_id,))
    before = cur.fetchone()[0]

    cur.execute("INSERT INTO orders (customer_id, order_date, status, total_amount)"
                " VALUES (%s, (SELECT report_as_of()) - 1, 'cancelled', 80) RETURNING order_id", (customer_id,))
    order_id = cur.fetchone()[0]
    cur.execute("INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (%s, %s, 2, 40)",
                (order_id, product_id))
    cur.execute("SELECT refresh_monday_report()")

    cur.execute("SELECT total_spent FROM mv_customer_spend_report WHERE customer_id = %s", (customer_id,))
    assert cur.fetchone()[0] == before


# checks that every category has exactly one full path, ending in its own name.
def test_every_category_has_one_path_ending_in_its_name(cur):
    cur.execute("SELECT count(*) FROM categories")
    categories = cur.fetchone()[0]
    cur.execute("SELECT count(*), count(DISTINCT category_id),"
                " count(*) FILTER (WHERE path NOT LIKE '%' || category_name) FROM v_category_paths")
    rows, distinct, wrong_ending = cur.fetchone()

    assert rows == distinct == categories
    assert wrong_ending == 0


# checks that the low-stock list holds only products at or under their reorder level,
# labelled correctly.
def test_the_low_stock_list_is_right(cur):
    cur.execute("""
        SELECT count(*) FROM v_low_stock_products
        WHERE stock_quantity > reorder_level
           OR (stock_quantity = 0) <> (state = 'out of stock')
    """)
    assert cur.fetchone()[0] == 0


# checks that the count list starts at 1 and puts the most money at risk first.
def test_the_count_list_puts_the_most_money_first(cur):
    cur.execute("SELECT count_order, value_at_risk FROM v_count_these_first ORDER BY count_order")
    rows = cur.fetchall()

    assert rows, "expected some stock drift in the supplied data"
    assert [r[0] for r in rows] == list(range(1, len(rows) + 1))
    values = [r[1] for r in rows]
    assert values == sorted(values, reverse=True)


# runs the build's own self checks file, which stops with an error if any output is wrong.
def test_the_build_self_checks_pass(db_conn):
    env = main.load_env()
    assert main.psql(env, "-q", "-v", "ON_ERROR_STOP=1", "-f", "sql/11_self_checks.sql") == 0


# runs the supplied race_test.py exactly as shipped and checks it passes.
@pytest.mark.slow
def test_the_supplied_race_test_passes(db_conn):
    env = main.load_env()
    result = subprocess.run(
        [main.python_for_race(), "race_test.py"],
        cwd=main.REPO / "M03_Resources",
        env={**os.environ, "DATABASE_URL": env["DATABASE_URL"]},
        capture_output=True, text=True, timeout=300,
    )
    assert result.returncode == 0, result.stdout[-2000:] + result.stderr[-2000:]
