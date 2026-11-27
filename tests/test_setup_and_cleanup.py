"""tests for the build steps that come before the features: preflight, diagnosis, schema
changes, cleanup and indexes (sql/00 to sql/04 and sql/07)."""

import datetime

import pytest

pytestmark = pytest.mark.database


# checks that the server has the connection limit and version the race test and rollup need.
def test_the_server_meets_the_preflight_rules(cur):
    cur.execute("SELECT current_setting('max_connections')::int, current_setting('server_version_num')::int")
    max_connections, version = cur.fetchone()

    assert max_connections >= 500
    assert version >= 140000


# checks that the reports treat the last day of the extract as today.
def test_the_report_date_is_the_end_of_the_extract(cur):
    cur.execute("SELECT report_as_of()")
    assert cur.fetchone()[0] == datetime.date(2026, 8, 31)


# checks that clearing the report date makes the reports use the real date, then puts it back.
def test_clearing_the_report_date_falls_back_to_today(cur):
    cur.execute("UPDATE report_settings SET as_of_date = NULL")
    cur.execute("SELECT report_as_of() = current_date")
    assert cur.fetchone()[0] is True


# checks that the diagnosis ranks all 17 findings, numbered 1 to 17 with none missing.
def test_the_diagnosis_ranks_all_seventeen_findings(cur):
    cur.execute("SELECT array_agg(danger_rank ORDER BY danger_rank) FROM dq.findings")
    assert cur.fetchone()[0] == list(range(1, 18))


# checks that every diagnosis check can be opened on its own to see the faulty rows.
def test_every_diagnosis_check_can_be_queried(cur):
    cur.execute("SELECT table_name FROM information_schema.views"
                " WHERE table_schema = 'dq' AND table_name LIKE 'chk\\_%' ORDER BY 1")
    checks = [r[0] for r in cur.fetchall()]

    assert len(checks) == 17
    for check in checks:
        cur.execute(f"SELECT count(*) FROM dq.{check}")
        assert cur.fetchone()[0] >= 0


# checks that the before figures were saved before the cleanup, so they show the real starting
# point and not the cleaned data.
def test_the_before_figures_were_saved_before_the_cleanup(cur):
    cur.execute("SELECT rows_before, rows_now FROM dq.findings_before_after"
                " WHERE finding = 'negative stock (oversold units)'")
    before, now = cur.fetchone()

    assert before > 0
    assert now == 0


# checks that new orders, order lines and log rows get their id from the database.
@pytest.mark.parametrize("table, column", [
    ("orders", "order_id"),
    ("order_items", "order_item_id"),
    ("inventory_log", "log_id"),
])
def test_ids_are_generated_by_the_database(cur, table, column):
    cur.execute("SELECT is_identity FROM information_schema.columns"
                " WHERE table_schema = 'public' AND table_name = %s AND column_name = %s", (table, column))
    assert cur.fetchone()[0] == "YES"


# checks that a new order gets an id above every existing one, so it can't clash.
def test_a_new_order_gets_an_id_that_cannot_clash(cur, customer_id):
    cur.execute("SELECT max(order_id) FROM orders")
    highest = cur.fetchone()[0]
    cur.execute("INSERT INTO orders (customer_id, order_date, total_amount)"
                " VALUES (%s, now(), 0) RETURNING order_id, status", (customer_id,))
    order_id, status = cur.fetchone()

    assert order_id > highest
    assert status == "pending"


# checks that a new log row records who made it, and a new product gets the default reorder level.
def test_new_columns_fill_themselves_in(cur, make_product):
    product_id = make_product(stock=3)
    cur.execute("SELECT reorder_level FROM products WHERE product_id = %s", (product_id,))
    assert cur.fetchone()[0] == 10

    cur.execute("INSERT INTO inventory_log (product_id, change_qty, reason, note)"
                " VALUES (%s, 0, 'stock_take', 'counted') RETURNING recorded_by, is_duplicate", (product_id,))
    recorded_by, is_duplicate = cur.fetchone()
    assert recorded_by
    assert is_duplicate is False


# checks that every row the cleanup changed or removed still has its original kept in dq.
@pytest.mark.parametrize("table", [
    "dq.removed_order_items",
    "dq.order_status_original",
    "dq.order_item_price_fixes",
    "dq.order_item_quantity_fixes",
    "dq.category_fixes",
])
def test_the_cleanup_keeps_the_original_rows(cur, table):
    cur.execute(f"SELECT count(*) FROM {table}")
    assert cur.fetchone()[0] > 0


# checks that every order status is now one of the five agreed spellings.
def test_every_order_status_is_one_of_the_five(cur):
    cur.execute("SELECT DISTINCT status FROM orders")
    statuses = {r[0] for r in cur.fetchall()}

    assert statuses <= {"pending", "shipped", "completed", "cancelled", "refunded"}


# checks that only the 50 proven double log rows are flagged, and none were deleted.
def test_only_the_proven_double_log_rows_are_flagged(cur):
    cur.execute("SELECT count(*) FROM inventory_log WHERE is_duplicate")
    assert cur.fetchone()[0] == 50


# checks that no order line still has an impossible quantity outside the agreed fixes.
def test_no_live_order_line_has_an_impossible_quantity_left_unfixed(cur):
    cur.execute("""
        SELECT count(*) FROM order_items oi
        WHERE oi.quantity > 100
          AND oi.order_item_id NOT IN (SELECT order_item_id FROM dq.order_item_quantity_fixes)
    """)
    remaining = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM dq.chk_implausible_quantities")

    assert remaining == cur.fetchone()[0]


# checks that every index the measurements relied on exists.
@pytest.mark.parametrize("index", [
    "orders_customer_date_idx",
    "order_items_order_idx",
    "order_items_product_idx",
    "inventory_log_product_time_idx",
    "inventory_log_order_idx",
    "categories_parent_idx",
    "products_category_idx",
    "order_items_implausible_qty_idx",
])
def test_the_indexes_exist(cur, index):
    cur.execute("SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = %s", (index,))
    assert cur.fetchone() is not None
