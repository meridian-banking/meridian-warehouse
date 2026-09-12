"""Load staged Parquet from the lake into the warehouse.

THE FLOW:
    staged S3/MinIO (Parquet)
        -> bulk COPY into staging.* tables      (fast, no transformation)
        -> SQL transforms into curated.*        (set-based, inside the database)

WHY BULK COPY RATHER THAN ROW-BY-ROW INSERT?
Postgres COPY streams data in a single operation with minimal per-row overhead.
Row-by-row INSERT does a network round trip and a parse per row — for 3M
transactions that is the difference between seconds and hours. If you take one
performance lesson from this sprint, it is: never loop INSERTs for bulk loads.

WHY TRANSFORM IN SQL RATHER THAN PANDAS?
Once data is in staging tables, joins and aggregations run inside the database
engine, on indexed columns, without moving data over the network. Pulling 3M
rows into pandas to transform and pushing them back is the classic beginner
architecture and it does not scale. "Push compute to the data."
"""

from __future__ import annotations

import io
import logging
from dataclasses import dataclass
from datetime import date

import pandas as pd
import psycopg2

logger = logging.getLogger("meridian_warehouse.loader")


@dataclass(frozen=True)
class WarehouseConfig:
    host: str
    port: int
    database: str
    user: str
    password: str

    def dsn(self) -> str:
        return (
            f"host={self.host} port={self.port} dbname={self.database} "
            f"user={self.user} password={self.password}"
        )


def bulk_load(conn, df: pd.DataFrame, table: str, columns: list[str]) -> int:
    """Bulk-copy a DataFrame into a staging table using COPY.

    We serialise to an in-memory CSV buffer and stream it. No temp files, one
    network operation, minimal overhead.
    """
    subset = df[columns]
    buf = io.StringIO()
    subset.to_csv(buf, index=False, header=False, na_rep="\\N")
    buf.seek(0)

    with conn.cursor() as cur:
        cur.execute(f"TRUNCATE {table}")  # staging holds only the current batch
        cur.copy_expert(
            f"COPY {table} ({', '.join(columns)}) FROM STDIN WITH CSV NULL '\\N'",
            buf,
        )
        cur.execute(f"SELECT count(*) FROM {table}")
        n = cur.fetchone()[0]
    conn.commit()
    logger.info("bulk loaded %s rows into %s", f"{n:,}", table)
    return n


def build_dim_date(conn, start: date, end: date) -> int:
    """Populate dim_date for a range. Pure SQL, using generate_series.

    generate_series is a Postgres set-returning function — it produces a row per
    date without any application-side loop. Another instance of pushing work
    into the database.
    """
    sql = """
    INSERT INTO curated.dim_date (
        date_key, full_date, year, quarter, month, month_name, week_of_year,
        day_of_month, day_of_week, day_name, is_weekend, is_business_day,
        is_month_end, is_quarter_end, is_year_end, fiscal_year, fiscal_quarter,
        prior_year_date_key, days_from_epoch
    )
    SELECT
        to_char(d, 'YYYYMMDD')::int                      AS date_key,
        d::date                                          AS full_date,
        extract(year FROM d)::smallint,
        extract(quarter FROM d)::smallint,
        extract(month FROM d)::smallint,
        to_char(d, 'Month'),
        extract(week FROM d)::smallint,
        extract(day FROM d)::smallint,
        extract(isodow FROM d)::smallint,
        to_char(d, 'Day'),
        extract(isodow FROM d) IN (6, 7)                 AS is_weekend,
        extract(isodow FROM d) NOT IN (6, 7)             AS is_business_day,
        d = (date_trunc('month', d) + interval '1 month - 1 day')::date,
        d = (date_trunc('quarter', d) + interval '3 months - 1 day')::date,
        d = (date_trunc('year', d) + interval '1 year - 1 day')::date,
        -- US federal fiscal year starts 1 October
        CASE WHEN extract(month FROM d) >= 10
             THEN extract(year FROM d) + 1 ELSE extract(year FROM d) END::smallint,
        'FY' || CASE WHEN extract(month FROM d) >= 10
                     THEN extract(year FROM d) + 1 ELSE extract(year FROM d) END
              || '-Q' || (((extract(month FROM d)::int + 2) %% 12) / 3 + 1),
        to_char(d - interval '1 year', 'YYYYMMDD')::int,
        (d::date - DATE '1970-01-01')                    AS days_from_epoch
    FROM generate_series(%s::date, %s::date, interval '1 day') AS d
    ON CONFLICT (date_key) DO NOTHING
    """
    with conn.cursor() as cur:
        cur.execute(sql, (start, end))
        cur.execute("SELECT count(*) FROM curated.dim_date")
        n = cur.fetchone()[0]
    conn.commit()
    logger.info("dim_date now has %s rows", f"{n:,}")
    return n


def merge_dim_customer(conn, effective_date: date, initial_load: bool = False) -> None:
    """Run the SCD Type 2 merge stored procedure.

    initial_load=True on the FIRST historical load, so dimension rows are valid
    from the beginning of history. Without it, historical facts find no matching
    dimension version and all fall through to the unknown member — a classic
    warehouse bootstrapping bug where the model is right but every join misses.
    """
    with conn.cursor() as cur:
        cur.execute("CALL curated.merge_dim_customer(%s, %s)", (effective_date, initial_load))
    conn.commit()
    logger.info("dim_customer merged as of %s (initial=%s)", effective_date, initial_load)


def merge_dim_branch(conn) -> None:
    """SCD Type 1 upsert for branches: overwrite on change, insert if new.

    ON CONFLICT ... DO UPDATE is Postgres' upsert. Contrast with the Type 2
    merge: no history, no valid_from/valid_to, just overwrite. Far simpler —
    which is exactly why you only pay for Type 2 where history is needed.
    """
    sql = """
    INSERT INTO curated.dim_branch (branch_id, branch_name, city, state, region, opened_date)
    SELECT
        s.branch_id, s.branch_name, s.city, s.state,
        CASE
            WHEN s.state IN ('CA','WA','OR','AZ','NV','CO') THEN 'West'
            WHEN s.state IN ('TX','GA','FL','NC','TN')      THEN 'South'
            WHEN s.state IN ('NY','NJ','PA','MA')           THEN 'Northeast'
            WHEN s.state IN ('IL','MN','OH','MI')           THEN 'Midwest'
            ELSE 'Other'
        END,
        s.opened_date
    FROM staging.stg_branches s
    ON CONFLICT (branch_id) DO UPDATE
        SET branch_name = EXCLUDED.branch_name,
            city        = EXCLUDED.city,
            state       = EXCLUDED.state,
            region      = EXCLUDED.region,
            opened_date = EXCLUDED.opened_date,
            updated_at  = now()
    """
    with conn.cursor() as cur:
        cur.execute(sql)
    conn.commit()
    logger.info("dim_branch merged")


def merge_dim_account(conn) -> None:
    """SCD Type 1 upsert for accounts."""
    sql = """
    INSERT INTO curated.dim_account
        (account_id, customer_id, product_type, product_family, apr,
         open_date, status, initial_balance)
    SELECT
        s.account_id, s.customer_id, s.product_type,
        CASE WHEN s.product_type = 'credit_card' THEN 'credit' ELSE 'deposit' END,
        s.apr, s.open_date, s.status, s.initial_balance
    FROM staging.stg_accounts s
    ON CONFLICT (account_id) DO UPDATE
        SET product_type    = EXCLUDED.product_type,
            product_family  = EXCLUDED.product_family,
            apr             = EXCLUDED.apr,
            status          = EXCLUDED.status,
            initial_balance = EXCLUDED.initial_balance,
            updated_at      = now()
    """
    with conn.cursor() as cur:
        cur.execute(sql)
    conn.commit()
    logger.info("dim_account merged")


def load_fact_transactions(conn, load_id: int | None = None) -> int:
    """Transform staged transactions into the fact table.

    THE KEY LINE IS THE dim_customer JOIN. Read it carefully:

        JOIN curated.dim_customer dc
          ON dc.customer_id = da.customer_id
         AND s.timestamp::date >= dc.valid_from
         AND s.timestamp::date <  dc.valid_to

    We do NOT join on `dc.is_current`. We join on the version that was valid AT
    THE TRANSACTION'S DATE. That is the whole payoff of SCD Type 2: a 2023
    transaction is attributed to the customer as they were in 2023, not as they
    are today. Joining on is_current instead is the single most common way
    people accidentally throw away the history they just built.

    LEFT JOIN + COALESCE to the unknown member (-1) keeps facts that reference a
    missing dimension row, rather than silently dropping them via INNER JOIN.
    """
    sql = """
    INSERT INTO curated.fact_transactions (
        transaction_id, date_key, account_key, customer_key, merchant_category_key,
        amount, transaction_ts, hour_of_day, channel, is_fraud, load_id
    )
    SELECT
        s.transaction_id,
        to_char(s.timestamp, 'YYYYMMDD')::int,
        COALESCE(da.account_key, unk_a.account_key),
        COALESCE(dc.customer_key, unk_c.customer_key),
        COALESCE(dmc.merchant_category_key, unk_m.merchant_category_key),
        s.amount,
        s.timestamp,
        extract(hour FROM s.timestamp)::smallint,
        s.channel,
        s.is_fraud,
        %s
    FROM staging.stg_transactions s
    JOIN curated.dim_date dd
      ON dd.date_key = to_char(s.timestamp, 'YYYYMMDD')::int
    LEFT JOIN curated.dim_account da
      ON da.account_id = s.account_id
    -- POINT-IN-TIME JOIN: the customer version valid at the transaction date
    LEFT JOIN curated.dim_customer dc
      ON dc.customer_id = da.customer_id
     AND s.timestamp::date >= dc.valid_from
     AND s.timestamp::date <  dc.valid_to
    LEFT JOIN curated.dim_merchant_category dmc
      ON dmc.category_code = s.merchant_category
    -- Unknown members, used when a lookup misses
    CROSS JOIN (SELECT account_key FROM curated.dim_account WHERE account_id='-1') unk_a
    CROSS JOIN (SELECT customer_key FROM curated.dim_customer WHERE customer_id='-1') unk_c
    CROSS JOIN (SELECT merchant_category_key FROM curated.dim_merchant_category
                 WHERE category_code='unknown') unk_m
    ON CONFLICT (transaction_id) DO NOTHING
    """
    with conn.cursor() as cur:
        cur.execute(sql, (load_id,))
        inserted = cur.rowcount
        cur.execute("SELECT count(*) FROM curated.fact_transactions")
        total = cur.fetchone()[0]
    conn.commit()
    logger.info("fact_transactions: inserted %s (total %s)", f"{inserted:,}", f"{total:,}")
    return inserted


def connect(cfg: WarehouseConfig):
    return psycopg2.connect(cfg.dsn())
