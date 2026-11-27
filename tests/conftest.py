"""shared test fixtures.

database tests connect with the settings in .env (the same ones main.py uses). if the
database isn't reachable they are skipped with a clear reason, so the unit tests can still
run on a machine without docker.
"""

import psycopg2
import pytest

import main

FIXTURE_PREFIX = "RACE TEST FIXTURE PYTEST"


# the connection string, read from .env.
@pytest.fixture(scope="session")
def dsn():
    return main.load_env()["DATABASE_URL"]


# one connection for the whole run. skips every database test if it can't connect.
@pytest.fixture(scope="session")
def db_conn(dsn):
    try:
        conn = psycopg2.connect(dsn, connect_timeout=5)
    except psycopg2.OperationalError as exc:
        pytest.skip(f"database not reachable, run `python main.py` first ({exc.args[0].splitlines()[0]})")
    yield conn
    conn.close()


# a cursor inside a transaction that is always rolled back, so a test can change anything
# without leaving a trace.
@pytest.fixture
def cur(db_conn):
    db_conn.rollback()
    cursor = db_conn.cursor()
    yield cursor
    cursor.close()
    db_conn.rollback()


# the first real customer, used for test orders.
@pytest.fixture
def customer_id(cur):
    cur.execute("SELECT min(customer_id) FROM customers")
    return cur.fetchone()[0]


# makes a throwaway product inside the test's transaction and returns its id.
@pytest.fixture
def make_product(cur):
    def _make(stock, price=10.00):
        cur.execute("SELECT coalesce(max(product_id), 0) + 1 FROM products")
        product_id = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO products (product_id, product_name, category_id, price, stock_quantity, created_at)"
            " VALUES (%s, %s, NULL, %s, %s, now())",
            (product_id, f"{FIXTURE_PREFIX} {product_id}", price, stock),
        )
        return product_id
    return _make
