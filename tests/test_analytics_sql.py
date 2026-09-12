"""Tests for the analytical SQL library.

WHY TEST QUERIES AT ALL?
A query that runs without error can still be WRONG — a mis-scoped PARTITION BY,
a bad join, an off-by-one frame. These tests assert the *semantics*: that a
running total actually accumulates, that dense_rank handles ties as documented,
that NOT EXISTS and NOT IN behave differently around NULLs.

Every test builds its own small fixture where the correct answer is known by
hand, which is the only way to verify analytical SQL with confidence.
"""

from __future__ import annotations

import os

import psycopg2
import pytest


@pytest.fixture(scope="module")
def conn():
    """Connection to the warehouse, with a scratch schema for fixtures."""
    dsn = (
        f"host={os.getenv('WAREHOUSE_HOST', 'localhost')} "
        f"port={os.getenv('WAREHOUSE_PORT', '5432')} "
        f"dbname={os.getenv('WAREHOUSE_DB', 'meridian')} "
        f"user={os.getenv('WAREHOUSE_USER', 'meridian')} "
        f"password={os.getenv('WAREHOUSE_PASSWORD', '')}"
    )
    connection = psycopg2.connect(dsn)
    connection.autocommit = True
    cur = connection.cursor()
    cur.execute("DROP SCHEMA IF EXISTS test_analytics CASCADE")
    cur.execute("CREATE SCHEMA test_analytics")
    cur.execute("SET search_path TO test_analytics, public")
    yield connection
    cur.execute("DROP SCHEMA IF EXISTS test_analytics CASCADE")
    connection.close()


@pytest.fixture(scope="module")
def sample_txns(conn):
    """A tiny transaction table whose correct answers we can compute by hand."""
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE t (
                acct text, ts timestamptz, amount numeric
            )
        """)
        cur.execute("""
            INSERT INTO t VALUES
                ('A', '2024-01-01 10:00', 100),
                ('A', '2024-01-02 10:00', 200),
                ('A', '2024-01-03 10:00', 300),
                ('B', '2024-01-01 10:00',  50),
                ('B', '2024-01-02 10:00',  50)   -- deliberate tie with the row above
        """)
    return True


# --- window function semantics ---------------------------------------------


def test_running_total_accumulates(conn, sample_txns):
    """SUM OVER with a to-current-row frame must accumulate, not repeat."""
    with conn.cursor() as cur:
        cur.execute("""
            SELECT amount,
                   SUM(amount) OVER (PARTITION BY acct ORDER BY ts
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
            FROM t WHERE acct = 'A' ORDER BY ts
        """)
        rows = cur.fetchall()
    assert [int(r[1]) for r in rows] == [100, 300, 600]


def test_partition_resets_the_running_total(conn, sample_txns):
    """PARTITION BY must restart the accumulation for each account."""
    with conn.cursor() as cur:
        cur.execute("""
            SELECT acct, SUM(amount) OVER (PARTITION BY acct ORDER BY ts
                                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
            FROM t ORDER BY acct, ts
        """)
        rows = cur.fetchall()
    first_of_b = next(r for r in rows if r[0] == "B")
    assert int(first_of_b[1]) == 50, "account B must start fresh, not continue from A"


def test_window_preserves_row_count(conn, sample_txns):
    """The defining property: windows add a column, they do not collapse rows."""
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM t")
        total = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM (SELECT SUM(amount) OVER () FROM t) x")
        windowed = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM (SELECT SUM(amount) FROM t GROUP BY acct) y")
        grouped = cur.fetchone()[0]
    assert windowed == total, "window must preserve every row"
    assert grouped < total, "GROUP BY must collapse rows"


def test_lag_returns_previous_row_and_null_at_start(conn, sample_txns):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT amount, LAG(amount) OVER (PARTITION BY acct ORDER BY ts)
            FROM t WHERE acct = 'A' ORDER BY ts
        """)
        rows = cur.fetchall()
    assert rows[0][1] is None, "first row has nothing before it"
    assert int(rows[1][1]) == 100
    assert int(rows[2][1]) == 200


def test_ranking_functions_differ_on_ties(conn, sample_txns):
    """ROW_NUMBER / RANK / DENSE_RANK must behave differently on a tie."""
    with conn.cursor() as cur:
        cur.execute("""
            SELECT ROW_NUMBER() OVER (ORDER BY amount),
                   RANK()       OVER (ORDER BY amount),
                   DENSE_RANK() OVER (ORDER BY amount)
            FROM t WHERE acct = 'B'
        """)
        rows = cur.fetchall()
    row_numbers = sorted(r[0] for r in rows)
    assert row_numbers == [1, 2], "ROW_NUMBER is always unique"
    assert all(r[1] == 1 for r in rows), "RANK: tied rows share the rank"
    assert all(r[2] == 1 for r in rows), "DENSE_RANK: tied rows share the rank"


def test_last_value_needs_a_widened_frame(conn, sample_txns):
    """The classic LAST_VALUE gotcha: the default frame stops at the current row."""
    with conn.cursor() as cur:
        cur.execute("""
            SELECT
                LAST_VALUE(amount) OVER (PARTITION BY acct ORDER BY ts) AS naive,
                LAST_VALUE(amount) OVER (PARTITION BY acct ORDER BY ts
                    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS correct
            FROM t WHERE acct = 'A' ORDER BY ts
        """)
        rows = cur.fetchall()
    assert int(rows[0][0]) == 100, "naive LAST_VALUE returns the current row"
    assert int(rows[0][1]) == 300, "widened frame returns the true last value"


# --- the NULL trap ----------------------------------------------------------


def test_not_in_with_null_returns_nothing(conn):
    """NOT IN against a set containing NULL yields no rows — the classic trap."""
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM (VALUES (1),(2),(3)) v(x) WHERE x NOT IN (2, NULL)")
        not_in_count = cur.fetchone()[0]
        cur.execute("""
            SELECT count(*) FROM (VALUES (1),(2),(3)) v(x)
            WHERE NOT EXISTS (SELECT 1 FROM (VALUES (2),(NULL)) w(y) WHERE w.y = v.x)
        """)
        not_exists_count = cur.fetchone()[0]
    assert not_in_count == 0, "NOT IN with a NULL returns zero rows"
    assert not_exists_count == 2, "NOT EXISTS handles NULLs correctly"


# --- gaps and islands -------------------------------------------------------


def test_gaps_and_islands_identifies_streaks(conn):
    """date - row_number must be constant within a run of consecutive dates."""
    with conn.cursor() as cur:
        cur.execute("DROP TABLE IF EXISTS d")
        cur.execute("CREATE TABLE d (day date)")
        # Two islands: Jan 1-3, then Jan 7-8 (a gap in between)
        cur.execute("""INSERT INTO d VALUES
            ('2024-01-01'),('2024-01-02'),('2024-01-03'),
            ('2024-01-07'),('2024-01-08')""")
        cur.execute("""
            WITH n AS (SELECT day, ROW_NUMBER() OVER (ORDER BY day) rn FROM d)
            SELECT MIN(day), MAX(day), COUNT(*)
            FROM (SELECT day, day - (rn || ' days')::interval AS grp FROM n) i
            GROUP BY grp ORDER BY MIN(day)
        """)
        islands = cur.fetchall()
    assert len(islands) == 2, "must find exactly two islands"
    assert islands[0][2] == 3, "first island is 3 days"
    assert islands[1][2] == 2, "second island is 2 days"


# --- conditional aggregation ------------------------------------------------


def test_filter_equals_case_when(conn, sample_txns):
    """FILTER and SUM(CASE WHEN...) must agree; FILTER is just cleaner."""
    with conn.cursor() as cur:
        cur.execute("""
            SELECT COUNT(*) FILTER (WHERE amount > 100),
                   SUM(CASE WHEN amount > 100 THEN 1 ELSE 0 END)
            FROM t
        """)
        filtered, case_when = cur.fetchone()
    assert filtered == case_when


# --- percentiles ------------------------------------------------------------


def test_median_differs_from_mean_on_skewed_data(conn):
    """On right-skewed data the mean exceeds the median — why we report both."""
    with conn.cursor() as cur:
        cur.execute("DROP TABLE IF EXISTS s")
        cur.execute("CREATE TABLE s (v numeric)")
        cur.execute("INSERT INTO s VALUES (10),(10),(10),(10),(1000)")
        cur.execute("""
            SELECT AVG(v), PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v)
            FROM s
        """)
        mean, median = cur.fetchone()
    assert float(mean) > float(median), "skew pulls the mean above the median"
    assert float(median) == 10.0
