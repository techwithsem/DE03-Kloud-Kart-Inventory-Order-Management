"""tests for the monday report, the category rollup, the drift check and the data cleanup."""

import pytest

pytestmark = pytest.mark.database


# checks that every customer appears in the report exactly once.
def test_the_report_has_exactly_one_row_per_customer(cur):
    cur.execute("SELECT (SELECT count(*) FROM customers),"
                " count(*), count(DISTINCT customer_id) FROM mv_customer_spend_report")
    customers, rows, distinct_customers = cur.fetchone()

    assert rows == customers == distinct_customers


# checks that the report's total spend equals the same sum worked out from the raw tables.
def test_report_spend_matches_the_raw_tables(cur):
    cur.execute("SELECT sum(total_spent) FROM mv_customer_spend_report")
    report_total = cur.fetchone()[0]
    cur.execute("""
        SELECT sum(oi.quantity * oi.unit_price)
        FROM orders o
        JOIN customers c ON c.customer_id = o.customer_id
        JOIN order_items oi ON oi.order_id = o.order_id
        WHERE o.status IN ('completed', 'shipped')
          AND o.order_date < (SELECT report_as_of()) + 1
          AND o.order_id NOT IN (SELECT order_id FROM order_items WHERE quantity > 100)
    """)
    raw_total = cur.fetchone()[0]

    assert abs(report_total - raw_total) < 0.01


# checks that the 12 monthly columns add up to the 12-month figure and each running total
# ends at the customer's total.
def test_the_twelve_months_add_up_and_running_totals_end_at_the_total(cur):
    cur.execute("""
        SELECT count(*) FROM mv_customer_spend_report
        WHERE abs(spend_12m - (spend_m01 + spend_m02 + spend_m03 + spend_m04 + spend_m05 + spend_m06
                             + spend_m07 + spend_m08 + spend_m09 + spend_m10 + spend_m11 + spend_m12)) > 0.01
    """)
    assert cur.fetchone()[0] == 0

    cur.execute("""
        SELECT count(*)
        FROM mv_customer_spend_report r
        JOIN (SELECT customer_id, max(running_total) AS last_total
              FROM mv_customer_monthly_spend GROUP BY customer_id) m USING (customer_id)
        WHERE abs(r.total_spent - m.last_total) > 0.01
    """)
    assert cur.fetchone()[0] == 0


# checks that the report covers 12 months in a row.
def test_the_report_covers_twelve_calendar_months(cur):
    cur.execute("SELECT count(*), min(month_start), max(month_start) FROM v_report_months")
    months, first, last = cur.fetchone()

    assert months == 12
    assert (last.year - first.year) * 12 + (last.month - first.month) == 11


# checks that the top 100 starts at rank 1 and runs from highest spend down.
def test_the_top_100_is_ranked_by_spend(cur):
    cur.execute("SELECT spend_rank, total_spent FROM v_top_100_customers ORDER BY spend_rank, customer_id")
    rows = cur.fetchall()

    assert len(rows) >= 100
    assert rows[0][0] == 1
    spends = [spend for _, spend in rows]
    assert spends == sorted(spends, reverse=True)


# checks that the top-level categories count every product once, none missed or doubled.
def test_the_rollup_counts_every_product_exactly_once_at_the_top(cur):
    cur.execute("SELECT count(*) FROM products WHERE product_name NOT LIKE 'RACE TEST FIXTURE%'")
    products = cur.fetchone()[0]
    cur.execute("SELECT sum(products) FROM v_low_stock_by_category WHERE depth = 1")

    assert cur.fetchone()[0] == products


# checks that no parent category shows fewer products than one of its children.
def test_a_parent_category_never_shows_fewer_products_than_a_child(cur):
    cur.execute("""
        SELECT count(*)
        FROM v_low_stock_by_category child
        JOIN categories c ON c.category_id = child.category_id
        JOIN v_low_stock_by_category parent ON parent.category_id = c.parent_id
        WHERE parent.products < child.products
    """)
    assert cur.fetchone()[0] == 0


# adds a new level under phones with an out-of-stock product, then checks the rollup picks it
# up with no code changes.
def test_a_new_subcategory_appears_in_the_rollup_without_code_changes(cur, make_product):
    cur.execute("SELECT category_id FROM categories WHERE category_name = 'Phones'")
    phones = cur.fetchone()[0]
    cur.execute("SELECT coalesce(max(category_id), 0) + 1 FROM categories")
    new_category = cur.fetchone()[0]
    cur.execute("INSERT INTO categories (category_id, category_name, parent_id) VALUES (%s, 'Test Deep Level', %s)",
                (new_category, phones))
    product_id = make_product(stock=0)
    # the rollup ignores race test fixtures by name, so this one gets an ordinary name.
    cur.execute("UPDATE products SET category_id = %s, product_name = 'Test Case' WHERE product_id = %s",
                (new_category, product_id))

    cur.execute("SELECT out_of_stock FROM v_low_stock_by_category WHERE category_id = %s", (new_category,))
    assert cur.fetchone()[0] == 1


# checks that the five faults the cleanup fixed are now at zero.
def test_the_faults_that_were_fixed_are_now_at_zero(cur):
    cur.execute("""
        SELECT finding, rows_now FROM dq.findings_before_after
        WHERE finding IN ('negative stock (oversold units)',
                          'order status spelled inconsistently',
                          'order lines entered twice',
                          'order lines with no order',
                          'category tree loops or dead ends')
    """)
    rows = dict(cur.fetchall())

    assert len(rows) == 5
    assert all(count == 0 for count in rows.values()), rows


# checks that no product is left with negative stock.
def test_no_product_has_negative_stock(cur):
    cur.execute("SELECT count(*) FROM products WHERE stock_quantity < 0")
    assert cur.fetchone()[0] == 0


# runs the drift check once to set a baseline, then breaks one healthy product and checks
# that's the only thing reported as new.
def test_the_drift_check_reports_only_new_problems(cur, make_product):
    cur.execute("SELECT count(*) FROM stock_drift_check()")
    product_id = make_product(stock=5)
    cur.execute("""
        SELECT product_id FROM products
        WHERE product_name NOT LIKE 'RACE TEST FIXTURE%'
          AND product_id NOT IN (SELECT product_id FROM v_stock_drift)
        ORDER BY product_id
        LIMIT 1
    """)
    healthy_product = cur.fetchone()[0]
    cur.execute("INSERT INTO inventory_log (product_id, change_qty, reason, note)"
                " VALUES (%s, -3, 'correction', 'recount, not applied')", (healthy_product,))

    cur.execute("SELECT product_id, status FROM stock_drift_check()")
    rows = cur.fetchall()

    assert rows == [(healthy_product, "new since last check")]
    assert product_id not in [r[0] for r in rows]
