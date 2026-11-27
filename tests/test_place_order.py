"""tests for place_order: sales, refusals, the audit trail and concurrency."""

import threading

import psycopg2
import pytest

from conftest import FIXTURE_PREFIX

pytestmark = pytest.mark.database


# calls place_order and returns (success, order_id, message).
def place(cur, customer_id, product_id, quantity):
    cur.execute("SELECT success, order_id, message FROM place_order(%s, %s, %s)",
                (customer_id, product_id, quantity))
    return cur.fetchone()


# checks that a sale lowers the stock and writes the order and its line.
def test_a_sale_takes_stock_and_creates_the_order(cur, customer_id, make_product):
    product_id = make_product(stock=3, price=25.00)

    success, order_id, _ = place(cur, customer_id, product_id, 2)

    assert success is True
    cur.execute("SELECT stock_quantity FROM products WHERE product_id = %s", (product_id,))
    assert cur.fetchone()[0] == 1
    cur.execute("SELECT customer_id, status, total_amount FROM orders WHERE order_id = %s", (order_id,))
    assert cur.fetchone() == (customer_id, "pending", 50.00)
    cur.execute("SELECT quantity, unit_price FROM order_items WHERE order_id = %s", (order_id,))
    assert cur.fetchone() == (2, 25.00)


# checks that each sale leaves one stock movement naming the order, the stock left and who made it.
def test_a_sale_leaves_a_full_audit_row(cur, customer_id, make_product):
    product_id = make_product(stock=5)

    _, order_id, _ = place(cur, customer_id, product_id, 1)

    cur.execute(
        "SELECT change_qty, reason, order_id, stock_after, recorded_by FROM inventory_log"
        " WHERE product_id = %s AND reason = 'sale'", (product_id,))
    rows = cur.fetchall()
    assert len(rows) == 1
    change_qty, reason, logged_order, stock_after, recorded_by = rows[0]
    assert (change_qty, logged_order, stock_after) == (-1, order_id, 4)
    assert recorded_by


# checks that only one of two buyers gets the last unit and the other is told it's out of stock.
def test_the_second_buyer_for_the_last_unit_is_told_out_of_stock(cur, customer_id, make_product):
    product_id = make_product(stock=1)

    first = place(cur, customer_id, product_id, 1)
    second = place(cur, customer_id, product_id, 1)

    assert first[0] is True
    assert second[0] is False
    assert second[1] is None
    assert "out of stock" in second[2].lower()


# checks that asking for more than is in stock is refused and the stock stays the same.
def test_asking_for_more_than_exists_is_refused_and_stock_is_untouched(cur, customer_id, make_product):
    product_id = make_product(stock=3)

    success, order_id, message = place(cur, customer_id, product_id, 10)

    assert success is False and order_id is None
    assert "out of stock" in message.lower()
    cur.execute("SELECT stock_quantity FROM products WHERE product_id = %s", (product_id,))
    assert cur.fetchone()[0] == 3


# checks that a quantity of zero or less is refused.
@pytest.mark.parametrize("quantity", [0, -1])
def test_a_quantity_below_one_is_refused(cur, customer_id, make_product, quantity):
    product_id = make_product(stock=3)

    success, _, message = place(cur, customer_id, product_id, quantity)

    assert success is False
    assert "at least 1" in message


# checks that an order for a customer who doesn't exist is refused.
def test_an_unknown_customer_is_refused(cur, make_product):
    product_id = make_product(stock=3)

    success, _, message = place(cur, 999999999, product_id, 1)

    assert success is False
    assert "customer" in message


# checks that an order for a product that doesn't exist is refused.
def test_an_unknown_product_is_refused(cur, customer_id):
    success, _, message = place(cur, customer_id, 999999999, 1)

    assert success is False
    assert "product" in message


# a product committed to the database, so separate connections can race for it.
# removed afterwards the same way race_test.py removes its fixtures.
@pytest.fixture
def committed_product(dsn, db_conn):
    created = []

    def _make(stock):
        with psycopg2.connect(dsn) as conn, conn.cursor() as c:
            c.execute("SELECT coalesce(max(product_id), 0) + 20000 FROM products")
            product_id = c.fetchone()[0]
            c.execute(
                "INSERT INTO products (product_id, product_name, category_id, price, stock_quantity, created_at)"
                " VALUES (%s, %s, NULL, 10.00, %s, now())",
                (product_id, f"{FIXTURE_PREFIX} race {product_id}", stock),
            )
        created.append(product_id)
        return product_id

    yield _make

    with psycopg2.connect(dsn) as conn, conn.cursor() as c:
        c.execute("SELECT DISTINCT order_id FROM order_items WHERE product_id = ANY(%s)", (created,))
        orders = [r[0] for r in c.fetchall()]
        c.execute("DELETE FROM order_items WHERE product_id = ANY(%s)", (created,))
        if orders:
            c.execute("DELETE FROM orders WHERE order_id = ANY(%s)", (orders,))
        c.execute("DELETE FROM inventory_log WHERE product_id = ANY(%s)", (created,))
        c.execute("DELETE FROM products WHERE product_id = ANY(%s)", (created,))


# releases 20 buyers on separate connections at the same moment for 5 units, then checks
# exactly 5 sold, the rest were told out of stock, and stock and the log agree.
def test_twenty_buyers_at_once_for_five_units_sell_exactly_five(dsn, db_conn, committed_product):
    product_id = committed_product(stock=5)
    with psycopg2.connect(dsn) as conn, conn.cursor() as c:
        c.execute("SELECT min(customer_id) FROM customers")
        customer_id = c.fetchone()[0]

    buyers = 20
    barrier = threading.Barrier(buyers)
    results, errors = [], []

    def buy():
        conn = psycopg2.connect(dsn)
        conn.autocommit = True
        try:
            barrier.wait(timeout=30)
            with conn.cursor() as c:
                c.execute("SELECT success, message FROM place_order(%s, %s, 1)", (customer_id, product_id))
                results.append(c.fetchone())
        except Exception as exc:
            errors.append(exc)
        finally:
            conn.close()

    threads = [threading.Thread(target=buy) for _ in range(buyers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=60)

    assert errors == []
    assert sum(1 for success, _ in results if success) == 5
    assert all("out of stock" in message.lower() for success, message in results if not success)
    with psycopg2.connect(dsn) as conn, conn.cursor() as c:
        c.execute("SELECT stock_quantity FROM products WHERE product_id = %s", (product_id,))
        assert c.fetchone()[0] == 0
        c.execute("SELECT count(*) FROM inventory_log WHERE product_id = %s AND reason = 'sale'", (product_id,))
        assert c.fetchone()[0] == 5
