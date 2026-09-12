"""Tests for the warehouse: schema structure and SCD Type 2 behaviour.

We spin up a real embedded PostgreSQL (pgserver) rather than mocking, because
the things we most need to verify — partial unique indexes, stored procedure
logic, constraint enforcement — only exist inside a real database. Mocking them
would test our mock, not our warehouse.
"""

from __future__ import annotations

import glob
import os
from datetime import date

import psycopg2  # noqa: E402
import pytest

MIGRATIONS = sorted(glob.glob(os.path.join("migrations", "*.sql")))


@pytest.fixture(scope="module")
def conn():
    """A dedicated test schema set, applied fresh, on the real warehouse.

    Uses your actual Docker Postgres (same one meridian-infra brings up) rather
    than a throwaway embedded database, since pgserver has no wheel on every
    platform. We use a DEDICATED set of schemas (test_staging, test_curated, ...)
    so this never touches your real curated/staging data, then drop them after.
    """
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

    # Isolate entirely from real data: run this suite inside its own schemas,
    # then set search_path so unqualified "staging."/"curated." refs in the
    # migration SQL resolve to the test schemas instead of the real ones.
    for schema in ("staging", "curated", "marts", "audit"):
        cur.execute(f"DROP SCHEMA IF EXISTS test_{schema} CASCADE")
        cur.execute(f"CREATE SCHEMA test_{schema}")
    cur.execute("SET search_path TO test_staging, test_curated, test_marts, test_audit, public")

    for path in MIGRATIONS:
        with open(path) as fh:
            sql = fh.read()
        for real, test in [
            ("staging.", "test_staging."),
            ("curated.", "test_curated."),
            ("marts.", "test_marts."),
            ("audit.", "test_audit."),
        ]:
            sql = sql.replace(real, test)
        cur.execute(sql)

    yield connection

    for schema in ("staging", "curated", "marts", "audit"):
        cur.execute(f"DROP SCHEMA IF EXISTS test_{schema} CASCADE")
    connection.close()


def load_customers(conn, rows):
    with conn.cursor() as cur:
        cur.execute("TRUNCATE stg_customers")
        for r in rows:
            cur.execute(
                """INSERT INTO stg_customers
                   (customer_id, first_name, last_name, age, annual_income,
                    credit_score, dti, segment, join_date, home_branch_id)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                r,
            )


ADA_V1 = ("CUST_TEST01", "Ada", "L", 36, 80000, 660, 0.30, "mass", "2020-01-15", "BR_1")
ADA_V2 = ("CUST_TEST01", "Ada", "L", 36, 145000, 745, 0.20, "affluent", "2020-01-15", "BR_1")


# --- structure ------------------------------------------------------------


@pytest.mark.parametrize(
    "table",
    [
        "dim_date",
        "dim_customer",
        "dim_account",
        "dim_branch",
        "dim_merchant_category",
        "dim_loan_product",
        "fact_transactions",
        "fact_daily_balances",
        "fact_loan_monthly",
    ],
)
def test_curated_table_exists(conn, table):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT 1 FROM information_schema.tables "
            "WHERE table_schema='test_curated' AND table_name=%s",
            (table,),
        )
        assert cur.fetchone() is not None


@pytest.mark.parametrize(
    "table,column",
    [
        ("dim_customer", "valid_from"),
        ("dim_customer", "valid_to"),
        ("dim_customer", "is_current"),
        ("dim_customer", "row_hash"),
    ],
)
def test_scd2_columns_present(conn, table, column):
    """A Type 2 dimension without validity columns is not Type 2."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT 1 FROM information_schema.columns "
            "WHERE table_schema='test_curated' AND table_name=%s AND column_name=%s",
            (table, column),
        )
        assert cur.fetchone() is not None


def test_unknown_members_exist(conn):
    """Every dimension needs an unknown member so facts are never dropped."""
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM dim_customer WHERE customer_id='-1'")
        assert cur.fetchone()[0] == 1
        cur.execute("SELECT count(*) FROM dim_account WHERE account_id='-1'")
        assert cur.fetchone()[0] == 1


def test_fact_grain_uniqueness_enforced(conn):
    """The grain must be enforced by a constraint, not just by convention."""
    with conn.cursor() as cur:
        cur.execute(
            """SELECT 1 FROM pg_constraint
               WHERE conname = 'uq_daily_balance_grain'"""
        )
        assert cur.fetchone() is not None


# --- SCD Type 2 behaviour -------------------------------------------------


def test_initial_load_inserts_current_row(conn):
    load_customers(conn, [ADA_V1])
    with conn.cursor() as cur:
        cur.execute("CALL merge_dim_customer(DATE '2024-01-01', TRUE)")
        cur.execute(
            "SELECT segment, is_current, valid_to FROM dim_customer WHERE customer_id='CUST_TEST01'"
        )
        rows = cur.fetchall()
    assert len(rows) == 1
    assert rows[0][0] == "mass"
    assert rows[0][1] is True
    assert rows[0][2] == date(9999, 12, 31)


def test_rerunning_unchanged_data_is_a_noop(conn):
    """Idempotency at the dimension level: no change means no new version."""
    load_customers(conn, [ADA_V1])
    with conn.cursor() as cur:
        cur.execute("CALL merge_dim_customer(DATE '2024-02-01')")
        cur.execute("SELECT count(*) FROM dim_customer WHERE customer_id='CUST_TEST01'")
        assert cur.fetchone()[0] == 1


def test_change_closes_old_row_and_opens_new(conn):
    load_customers(conn, [ADA_V2])
    with conn.cursor() as cur:
        cur.execute("CALL merge_dim_customer(DATE '2024-03-15')")
        cur.execute(
            """SELECT segment, valid_from, valid_to, is_current
               FROM dim_customer WHERE customer_id='CUST_TEST01'
               ORDER BY valid_from"""
        )
        rows = cur.fetchall()

    assert len(rows) == 2, "a change must produce a second version"
    old, new = rows
    assert old[0] == "mass" and old[3] is False, "old version must be closed"
    assert old[2] == date(2024, 3, 15), "old version must end on the change date"
    assert new[0] == "affluent" and new[3] is True, "new version must be current"
    assert new[1] == date(2024, 3, 15), "new version must start on the change date"


def test_exactly_one_current_row_per_customer(conn):
    with conn.cursor() as cur:
        cur.execute(
            """SELECT customer_id, count(*) FROM dim_customer
               WHERE is_current GROUP BY customer_id HAVING count(*) > 1"""
        )
        assert cur.fetchall() == []


def test_duplicate_current_row_is_rejected_by_database(conn):
    """Defense in depth: the DB must refuse invalid state even if code is buggy."""
    with conn.cursor() as cur, pytest.raises(psycopg2.errors.UniqueViolation):
        cur.execute(
            """INSERT INTO dim_customer
               (customer_id, first_name, last_name, full_name,
                valid_from, valid_to, is_current, row_hash)
               VALUES ('CUST_TEST01','Ada','L','Ada L',
                       DATE '2024-06-01', DATE '9999-12-31', TRUE, 'dupe')"""
        )


def test_point_in_time_query_returns_exactly_one_version(conn):
    """The half-open interval must guarantee no gaps and no overlaps."""
    with conn.cursor() as cur:
        for as_of, expected in [
            (date(2024, 2, 1), "mass"),
            (date(2024, 3, 14), "mass"),
            (date(2024, 3, 15), "affluent"),
            (date(2024, 12, 1), "affluent"),
        ]:
            cur.execute(
                """SELECT segment FROM dim_customer
                   WHERE customer_id='CUST_TEST01'
                     AND %s >= valid_from AND %s < valid_to""",
                (as_of, as_of),
            )
            rows = cur.fetchall()
            assert len(rows) == 1, f"{as_of}: expected exactly one version"
            assert rows[0][0] == expected, f"{as_of}: expected {expected}"


def test_validity_windows_never_overlap(conn):
    """No customer may have two versions covering the same date."""
    with conn.cursor() as cur:
        cur.execute(
            """SELECT a.customer_id
               FROM dim_customer a
               JOIN dim_customer b
                 ON a.customer_id = b.customer_id
                AND a.customer_key <> b.customer_key
                AND a.valid_from < b.valid_to
                AND b.valid_from < a.valid_to"""
        )
        assert cur.fetchall() == []


def test_null_handling_in_row_hash(conn):
    """A NULL attribute must not blank the hash and break change detection."""
    with conn.cursor() as cur:
        cur.execute("SELECT customer_row_hash('A', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)")
        value = cur.fetchone()[0]
    assert value is not None and len(value) == 32
