-- =============================================================================
-- 009: VIEWS AND MATERIALIZED VIEWS
-- =============================================================================
-- WHY VIEWS AT ALL?
-- A view is a saved query. It gives analysts a simple, correct starting point
-- instead of everyone re-deriving the same joins (and each getting them subtly
-- wrong). It is also a SEMANTIC LAYER: business definitions like "what counts
-- as an active customer" live in one place.
--
-- VIEW vs MATERIALIZED VIEW (a guaranteed interview question):
--   VIEW              — stores only the query text. Runs fresh every time.
--                       Always current; costs full compute on every read.
--   MATERIALIZED VIEW — stores the RESULT on disk. Reads are fast, but the data
--                       is a snapshot and goes stale until you REFRESH it.
-- Rule of thumb: use a plain view for cheap queries and anything that must be
-- real-time; use a materialized view for expensive aggregations over large
-- facts that are read far more often than the underlying data changes.
-- =============================================================================


-- =============================================================================
-- v_current_customers — the "just give me customers as they are today" view
-- =============================================================================
-- SCD Type 2 is powerful but forces every analyst to think about validity
-- windows. Most day-to-day questions ("how many affluent customers do we have?")
-- only care about the current state. This view hides the Type 2 machinery for
-- that common case, while the full table remains available for point-in-time work.
CREATE OR REPLACE VIEW marts.v_current_customers AS
SELECT
    customer_key, customer_id, full_name, age, annual_income,
    credit_score, credit_band, dti, segment, join_date, home_branch_id
FROM curated.dim_customer
WHERE is_current
  AND customer_id <> '-1';

COMMENT ON VIEW marts.v_current_customers IS
    'Current version of each customer. Hides SCD2 validity windows for the '
    'common case; use dim_customer directly for point-in-time analysis.';


-- =============================================================================
-- v_customer_history — the opposite view: make history EASY to see
-- =============================================================================
CREATE OR REPLACE VIEW marts.v_customer_history AS
SELECT
    customer_id,
    customer_key,
    segment,
    credit_band,
    credit_score,
    valid_from,
    valid_to,
    is_current,
    -- How long did this version last? Useful for "how often do customers
    -- change segment?" analysis.
    CASE WHEN is_current THEN NULL
         ELSE valid_to - valid_from END AS days_in_version,
    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY valid_from) AS version_number
FROM curated.dim_customer
WHERE customer_id <> '-1';

COMMENT ON VIEW marts.v_customer_history IS
    'Full SCD2 history per customer with version numbering and duration.';


-- =============================================================================
-- v_transaction_enriched — the "one-stop" analyst view
-- =============================================================================
-- This is the star schema JOINED BACK TOGETHER for convenience. Analysts get a
-- flat, wide table without writing the joins themselves — and crucially, the
-- joins are written CORRECTLY here once (including the point-in-time semantics
-- already baked into the fact's customer_key).
CREATE OR REPLACE VIEW marts.v_transaction_enriched AS
SELECT
    f.transaction_id,
    d.full_date,
    d.year,
    d.month,
    d.month_name,
    d.day_name,
    d.is_weekend,
    f.transaction_ts,
    f.hour_of_day,
    f.amount,
    f.channel,
    f.is_fraud,
    mc.category_name        AS merchant_category,
    mc.is_discretionary,
    mc.fraud_risk_tier,
    a.account_id,
    a.product_type,
    a.product_family,
    -- NOTE: these customer attributes are AS OF THE TRANSACTION DATE, because
    -- the fact's customer_key points at the SCD2 version valid then.
    c.customer_id,
    c.full_name             AS customer_name,
    c.segment               AS segment_at_txn_time,
    c.credit_band           AS credit_band_at_txn_time
FROM curated.fact_transactions f
JOIN curated.dim_date d               ON d.date_key = f.date_key
JOIN curated.dim_account a            ON a.account_key = f.account_key
JOIN curated.dim_customer c           ON c.customer_key = f.customer_key
JOIN curated.dim_merchant_category mc ON mc.merchant_category_key = f.merchant_category_key;

COMMENT ON VIEW marts.v_transaction_enriched IS
    'Denormalized transaction view. Customer attributes are as-of the '
    'transaction date (point-in-time), not current values.';


-- =============================================================================
-- mv_monthly_transaction_summary — MATERIALIZED, because it is expensive
-- =============================================================================
-- Aggregating millions of transaction rows by month/segment/category on every
-- dashboard load is wasteful: the answer for a CLOSED month never changes.
-- We materialize it and refresh nightly.
--
-- REFRESH STRATEGY (document this — interviewers ask):
--   - Refreshed by the nightly Airflow DAG after the warehouse load completes.
--   - CONCURRENTLY so readers are not blocked during refresh. That requires a
--     UNIQUE index on the materialized view, which is why we create one below.
--   - Staleness tolerance: up to 24h. Acceptable because this feeds monthly
--     trend reporting, not real-time operations. Fraud monitoring reads the
--     base fact table directly for that reason.
-- =============================================================================
DROP MATERIALIZED VIEW IF EXISTS marts.mv_monthly_transaction_summary;
CREATE MATERIALIZED VIEW marts.mv_monthly_transaction_summary AS
SELECT
    d.year,
    d.month,
    c.segment,
    mc.category_name                                        AS merchant_category,
    count(*)                                                AS transaction_count,
    sum(f.amount)                                           AS total_amount,
    avg(f.amount)                                           AS avg_amount,
    count(*) FILTER (WHERE f.is_fraud)                      AS fraud_count,
    sum(f.amount) FILTER (WHERE f.is_fraud)                 AS fraud_amount,
    count(DISTINCT f.customer_key)                          AS distinct_customers
FROM curated.fact_transactions f
JOIN curated.dim_date d               ON d.date_key = f.date_key
JOIN curated.dim_customer c           ON c.customer_key = f.customer_key
JOIN curated.dim_merchant_category mc ON mc.merchant_category_key = f.merchant_category_key
GROUP BY d.year, d.month, c.segment, mc.category_name;

-- NOTE the FILTER clause above: `count(*) FILTER (WHERE f.is_fraud)` is the
-- SQL-standard way to do conditional aggregation. It is cleaner and often
-- faster than `sum(CASE WHEN ... THEN 1 ELSE 0 END)`, and knowing it exists
-- is a small but real signal of SQL fluency.

-- Required for REFRESH ... CONCURRENTLY.
CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_monthly_summary
    ON marts.mv_monthly_transaction_summary (year, month, segment, merchant_category);

COMMENT ON MATERIALIZED VIEW marts.mv_monthly_transaction_summary IS
    'Monthly transaction aggregates by segment and category. Refreshed nightly '
    'via REFRESH MATERIALIZED VIEW CONCURRENTLY. Staleness tolerance: 24h.';
