# meridian-warehouse

Dimensional warehouse for the **Meridian Financial Intelligence & Risk Analytics Platform**. Turns the lake's staged Parquet into star schemas in PostgreSQL: surrogate keys, SCD Type 2 customer history, fact tables with declared grain, indexes chosen with reasoning, views, and a materialized view.

Consumes the staged zone written by `meridian-ingestion`. Feeds `meridian-analytics`, `meridian-ml`, and the Tableau dashboards.

## The model

**Dimensions**

| Table | SCD Type | Grain | Why this type |
|---|---|---|---|
| `dim_customer` | **Type 2** | one row per customer *per version* | Segment and credit band history is needed for point-in-time and fair-lending analysis |
| `dim_account` | Type 1 | one row per account | Product type effectively never changes; nobody asks about its history |
| `dim_branch` | Type 1 | one row per branch | Same |
| `dim_date` | static | one row per calendar date | Calendar logic defined once, consistently |
| `dim_merchant_category` | static | one row per category | Carries derived attributes (discretionary, risk tier) |
| `dim_loan_product` | static | one row per loan type | Carries `is_secured`, which drives LGD |

**Facts — grain declared explicitly**

| Table | Grain | Fact type |
|---|---|---|
| `fact_transactions` | one row per transaction | Transactional |
| `fact_daily_balances` | one row per account per day | Periodic snapshot |
| `fact_loan_monthly` | one row per loan per month | Periodic snapshot |

## Quick start

```bash
pip install -e ".[dev]"

export WAREHOUSE_HOST=localhost
export WAREHOUSE_PORT=5432
export WAREHOUSE_DB=meridian
export WAREHOUSE_USER=meridian
export WAREHOUSE_PASSWORD=<your warehouse password>

python -m meridian_warehouse migrate
python -m meridian_warehouse load --source-dir ../meridian-data-generator/output/parquet --initial
python -m meridian_warehouse refresh-views
```

`--initial` matters: on the first historical load, dimension rows must be valid from the beginning of history, otherwise historical facts find no matching version and all fall through to the unknown member.

## Key design decisions

**SCD Type 2 on customers.** When a tracked attribute changes, the current row is closed (`valid_to` set, `is_current` false) and a new row inserted. Facts join to the version valid *at the fact's date*, not the current one — that point-in-time join is the entire payoff, and joining on `is_current` instead silently discards the history.

**Half-open validity intervals.** `date >= valid_from AND date < valid_to`, with `9999-12-31` for open rows rather than NULL. Guarantees exactly one matching version — no gaps, no overlaps — and keeps queries index-friendly without `COALESCE`.

**Change detection by hash.** Tracked attributes are hashed into `row_hash`; comparing hashes beats a ten-column `IS DISTINCT FROM` chain. Note `IS DISTINCT FROM`, not `<>`: `NULL <> NULL` is NULL, so naive comparison misses NULL-involved changes. Every column is `COALESCE`d before hashing, or one NULL blanks the whole hash.

**Partial unique index on `(customer_id) WHERE is_current`.** The database itself refuses to store two current versions of a customer. Defense in depth: don't just trust the pipeline, make invalid state unrepresentable.

**Unknown members (key `-1`).** Facts referencing a missing dimension row point here rather than being dropped by an inner join or left NULL. Wrong-but-visible beats missing-and-silent.

**Degenerate dimensions.** `transaction_id` and `loan_id` live on the fact with no dimension table, because they carry no attributes worth storing.

**Star, not snowflake.** `region` is denormalized into `dim_branch` rather than split into `dim_region`. Fewer joins, simpler queries; the update-anomaly argument for snowflaking matters little when dimensions are rebuilt by a pipeline.

See [`docs/adr/`](docs/adr/) for the full decision records.

## Analytical SQL

[`analytics-sql/`](analytics-sql/) holds documented queries, each stating its business question and the grain of its answer — point-in-time lookup, running balances, month-over-month growth, top-N per segment, fraud rate by category, and segment migration (a query only possible *because* of SCD Type 2).

## Development

```bash
make test    # spins up a real embedded PostgreSQL, applies migrations, tests SCD2
make lint
make fmt
```

Tests use `pgserver` (embedded PostgreSQL) rather than mocks, because partial unique indexes, stored-procedure logic, and constraint enforcement only exist in a real database — mocking them would test the mock.

CI additionally applies every migration to an **empty** PostgreSQL, because a migration that only works against a developer's existing database is broken.

Part of the 8-repository Meridian platform.
