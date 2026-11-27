"""tests for the stock routine, the audit trigger and the rules that stop bad data coming back."""

import psycopg2
import pytest
from psycopg2 import errors

pytestmark = pytest.mark.database


# checks that a restock raises the stock and is written to the log with its note.
def test_a_restock_is_applied_and_logged(cur, make_product):
    product_id = make_product(stock=2)

    cur.execute("SELECT record_stock_movement(%s, 10, 'restock', 'supplier delivery')", (product_id,))

    assert cur.fetchone()[0] == 12
    cur.execute("SELECT change_qty, reason, note, stock_after FROM inventory_log"
                " WHERE product_id = %s ORDER BY log_id DESC LIMIT 1", (product_id,))
    assert cur.fetchone() == (10, "restock", "supplier delivery", 12)


# checks that a correction has to say why it was made.
def test_a_correction_without_a_note_is_refused(cur, make_product):
    product_id = make_product(stock=2)

    with pytest.raises(errors.RaiseException, match="needs a note"):
        cur.execute("SELECT record_stock_movement(%s, -1, 'correction', NULL)", (product_id,))


# checks that a movement taking stock below zero is refused.
def test_a_movement_that_would_go_below_zero_is_refused(cur, make_product):
    product_id = make_product(stock=2)

    with pytest.raises(errors.RaiseException, match="below zero"):
        cur.execute("SELECT record_stock_movement(%s, -5, 'damage', 'dropped')", (product_id,))


# checks that sales are refused here, so they can only happen through place_order.
def test_sales_cannot_go_through_the_stock_routine(cur, make_product):
    product_id = make_product(stock=2)

    with pytest.raises(errors.RaiseException, match="place_order"):
        cur.execute("SELECT record_stock_movement(%s, -1, 'sale', 'sold')", (product_id,))


# checks that a stock change typed straight into the table is still caught and logged.
def test_a_hand_typed_stock_change_is_still_logged(cur, make_product):
    product_id = make_product(stock=2)

    cur.execute("UPDATE products SET stock_quantity = 7 WHERE product_id = %s", (product_id,))

    cur.execute("SELECT change_qty, reason, note, stock_after FROM inventory_log"
                " WHERE product_id = %s ORDER BY log_id DESC LIMIT 1", (product_id,))
    change_qty, reason, note, stock_after = cur.fetchone()
    assert (change_qty, reason, stock_after) == (5, "correction", 7)
    assert "not through the stock routines" in note


# checks that the table itself refuses negative stock.
def test_stock_can_never_be_set_below_zero(cur, make_product):
    product_id = make_product(stock=2)

    with pytest.raises(errors.CheckViolation):
        cur.execute("UPDATE products SET stock_quantity = -1 WHERE product_id = %s", (product_id,))


# checks that an order status outside the agreed five, such as 'Completed', is refused.
def test_only_the_five_agreed_statuses_are_allowed(cur):
    with pytest.raises(errors.CheckViolation):
        cur.execute("UPDATE orders SET status = 'Completed' WHERE order_id = (SELECT min(order_id) FROM orders)")


# checks that an order can't point at a customer who doesn't exist.
def test_an_order_for_a_customer_who_does_not_exist_is_refused(cur):
    with pytest.raises(errors.ForeignKeyViolation):
        cur.execute("INSERT INTO orders (customer_id, order_date, status, total_amount)"
                    " VALUES (999999999, now(), 'pending', 10)")


# checks that an order line of 999 units is refused.
def test_an_impossible_quantity_is_refused(cur, customer_id, make_product):
    product_id = make_product(stock=2)
    cur.execute("INSERT INTO orders (customer_id, order_date, status, total_amount)"
                " VALUES (%s, now(), 'pending', 10) RETURNING order_id", (customer_id,))
    order_id = cur.fetchone()[0]

    with pytest.raises(errors.CheckViolation):
        cur.execute("INSERT INTO order_items (order_id, product_id, quantity, unit_price)"
                    " VALUES (%s, %s, 999, 10)", (order_id, product_id))


# checks that making electronics a child of its own child, phones, is refused.
def test_a_category_loop_is_refused(cur):
    cur.execute("SELECT category_id FROM categories WHERE category_name = 'Electronics'")
    electronics = cur.fetchone()[0]
    cur.execute("SELECT category_id FROM categories WHERE category_name = 'Phones'")
    phones = cur.fetchone()[0]

    with pytest.raises(errors.RaiseException, match="loop"):
        cur.execute("UPDATE categories SET parent_id = %s WHERE category_id = %s", (phones, electronics))


# checks that a category can't be its own parent.
def test_a_category_cannot_be_its_own_parent(cur):
    with pytest.raises((errors.CheckViolation, errors.RaiseException)):
        cur.execute("UPDATE categories SET parent_id = category_id"
                    " WHERE category_id = (SELECT min(category_id) FROM categories)")


# checks that a required column can't be left empty.
def test_key_columns_are_required(cur):
    with pytest.raises(errors.NotNullViolation):
        cur.execute("INSERT INTO orders (customer_id, order_date, status, total_amount)"
                    " VALUES (NULL, now(), 'pending', 10)")
