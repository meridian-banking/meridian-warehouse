"""Command-line interface for the warehouse.

python -m meridian_warehouse migrate
python -m meridian_warehouse load --source-dir ./staged --initial
python -m meridian_warehouse refresh-views
"""

from __future__ import annotations

import argparse
import glob
import logging
import os
import sys
from datetime import date, datetime
from pathlib import Path

import pandas as pd

from .loader import (
    WarehouseConfig,
    build_dim_date,
    bulk_load,
    connect,
    load_fact_transactions,
    merge_dim_account,
    merge_dim_branch,
    merge_dim_customer,
)

logger = logging.getLogger("meridian_warehouse")

STAGING_SPEC = {
    "branches": (
        "staging.stg_branches",
        ["branch_id", "branch_name", "city", "state", "opened_date"],
    ),
    "customers": (
        "staging.stg_customers",
        [
            "customer_id",
            "first_name",
            "last_name",
            "age",
            "annual_income",
            "credit_score",
            "dti",
            "segment",
            "join_date",
            "home_branch_id",
        ],
    ),
    "accounts": (
        "staging.stg_accounts",
        [
            "account_id",
            "customer_id",
            "product_type",
            "apr",
            "open_date",
            "status",
            "initial_balance",
        ],
    ),
    "transactions": (
        "staging.stg_transactions",
        [
            "transaction_id",
            "account_id",
            "timestamp",
            "amount",
            "merchant_category",
            "channel",
            "is_fraud",
        ],
    ),
    "loans": (
        "staging.stg_loans",
        [
            "loan_id",
            "customer_id",
            "loan_type",
            "principal",
            "apr",
            "term_months",
            "origination_date",
            "monthly_payment",
            "credit_score_at_origination",
            "dti_at_origination",
            "defaulted",
        ],
    ),
}


def config_from_env() -> WarehouseConfig:
    return WarehouseConfig(
        host=os.getenv("WAREHOUSE_HOST", "localhost"),
        port=int(os.getenv("WAREHOUSE_PORT", "5432")),
        database=os.getenv("WAREHOUSE_DB", "meridian"),
        user=os.getenv("WAREHOUSE_USER", "meridian"),
        password=os.getenv("WAREHOUSE_PASSWORD", ""),
    )


def cmd_migrate(args) -> int:
    """Apply every migration file in order.

    Migrations are numbered and idempotent (CREATE ... IF NOT EXISTS,
    CREATE OR REPLACE), so re-running is safe. Real teams eventually adopt a
    migration tool (Flyway, Alembic, Liquibase) that tracks which migrations
    have run; numbered idempotent files are the honest minimum version.
    """
    conn = connect(config_from_env())
    conn.autocommit = True
    files = sorted(glob.glob(str(Path(args.migrations_dir) / "*.sql")))
    if not files:
        logger.error("no migration files found in %s", args.migrations_dir)
        return 1

    with conn.cursor() as cur:
        for schema in ("staging", "curated", "marts", "audit"):
            cur.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
        for path in files:
            logger.info("applying %s", Path(path).name)
            cur.execute(Path(path).read_text())
    conn.close()
    logger.info("applied %d migrations", len(files))
    return 0


def cmd_load(args) -> int:
    """Load staged Parquet into staging tables, then transform into curated."""
    conn = connect(config_from_env())
    source = Path(args.source_dir)

    logger.info("building dim_date")
    build_dim_date(conn, date(2020, 1, 1), date(2030, 12, 31))

    for entity, (table, columns) in STAGING_SPEC.items():
        matches = list(source.glob(f"{entity}/**/*.parquet")) + list(
            source.glob(f"{entity}/*.parquet")
        )
        if not matches:
            logger.warning("no parquet found for %s, skipping", entity)
            continue
        df = pd.read_parquet(matches[0])
        if args.limit:
            df = df.head(args.limit)
        bulk_load(conn, df, table, columns)

    logger.info("merging dimensions")
    merge_dim_branch(conn)
    merge_dim_customer(conn, args.effective_date, initial_load=args.initial)
    merge_dim_account(conn)

    logger.info("loading facts")
    load_fact_transactions(conn)

    conn.close()
    return 0


def cmd_refresh_views(args) -> int:
    """Refresh materialized views. CONCURRENTLY so readers are not blocked."""
    conn = connect(config_from_env())
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY marts.mv_monthly_transaction_summary")
    conn.close()
    logger.info("materialized views refreshed")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="meridian_warehouse")
    parser.add_argument("--log-level", default="INFO")
    sub = parser.add_subparsers(dest="command", required=True)

    p_mig = sub.add_parser("migrate", help="apply all migrations")
    p_mig.add_argument("--migrations-dir", default="migrations")
    p_mig.set_defaults(func=cmd_migrate)

    p_load = sub.add_parser("load", help="load staged data into the warehouse")
    p_load.add_argument("--source-dir", required=True)
    p_load.add_argument(
        "--effective-date",
        type=lambda s: datetime.strptime(s, "%Y-%m-%d").date(),
        default=date.today(),
    )
    p_load.add_argument(
        "--initial",
        action="store_true",
        help="initial historical load: dimensions valid from beginning of history",
    )
    p_load.add_argument("--limit", type=int, default=None, help="row cap for testing")
    p_load.set_defaults(func=cmd_load)

    p_ref = sub.add_parser("refresh-views", help="refresh materialized views")
    p_ref.set_defaults(func=cmd_refresh_views)

    args = parser.parse_args(argv)
    logging.basicConfig(
        level=args.log_level,
        format="%(asctime)s  %(levelname)-7s  %(name)-26s  %(message)s",
        datefmt="%H:%M:%S",
    )
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
