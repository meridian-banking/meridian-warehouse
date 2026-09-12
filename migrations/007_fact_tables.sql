-- =============================================================================
-- 007: FACT TABLES
-- =============================================================================
-- Every fact table declares its GRAIN in one sentence before anything else.
-- Grain = "what does exactly ONE ROW of this table represent?"
--
-- This is the first question in any dimensional design and the most common
-- interview question in this whole area. Get it wrong and every SUM() on the
-- table is silently incorrect — the worst kind of bug, because nothing errors.
--
-- THE THREE FACT TABLE TYPES (know these by name):
--   1. TRANSACTIONAL  — one row per event as it happens (fact_transactions)
--   2. PERIODIC SNAPSHOT — one row per entity per time period, whether or not
--      anything happened (fact_daily_balances, fact_loan_monthly)
--   3. ACCUMULATING SNAPSHOT — one row per process instance, UPDATED as it moves
--      through milestones (a loan application: applied -> reviewed -> decided)
-- =============================================================================


-- =============================================================================
-- fact_transactions — TRANSACTIONAL FACT
-- GRAIN: exactly one row per transaction.
-- =============================================================================
CREATE TABLE IF NOT EXISTS curated.fact_transactions (
    transaction_key       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- DEGENERATE DIMENSION: the source transaction id lives right here on the
    -- fact, with no dim_transaction table. Why? Because it has no attributes
    -- worth storing — it's just an identifier used for drill-through and
    -- deduplication. A dimension with nothing but a key IS a degenerate
    -- dimension, and the correct handling is to keep it on the fact.
    transaction_id        TEXT        NOT NULL UNIQUE,

    -- FOREIGN KEYS to dimensions (all surrogate keys, never natural keys)
    date_key              INTEGER     NOT NULL REFERENCES curated.dim_date(date_key),
    account_key           BIGINT      NOT NULL REFERENCES curated.dim_account(account_key),
    customer_key          BIGINT      NOT NULL REFERENCES curated.dim_customer(customer_key),
    merchant_category_key BIGINT      NOT NULL
        REFERENCES curated.dim_merchant_category(merchant_category_key),

    -- MEASURES: the numbers you would SUM or AVG. This is what makes it a fact.
    amount                NUMERIC(16,2) NOT NULL,

    -- Attributes that describe this specific event (low cardinality, kept here
    -- rather than as separate dimensions to avoid pointless tiny joins)
    transaction_ts        TIMESTAMPTZ NOT NULL,
    hour_of_day           SMALLINT    NOT NULL,
    channel               TEXT        NOT NULL,
    is_fraud              BOOLEAN     NOT NULL,

    load_id               BIGINT,      -- lineage: which pipeline run wrote this
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE curated.fact_transactions IS
    'GRAIN: one row per transaction. Transactional fact.';

-- INDEXING STRATEGY, with reasoning:
-- 1) Nearly every analytical query filters or groups by date -> index date_key.
CREATE INDEX IF NOT EXISTS idx_fact_txn_date ON curated.fact_transactions (date_key);
-- 2) Join performance to the big dimensions.
CREATE INDEX IF NOT EXISTS idx_fact_txn_account ON curated.fact_transactions (account_key);
CREATE INDEX IF NOT EXISTS idx_fact_txn_customer ON curated.fact_transactions (customer_key);
-- 3) PARTIAL index for fraud analysis. Fraud is ~0.15% of rows, so an index on
--    JUST those rows is tiny (thousands of entries, not millions) while making
--    every fraud query fast. Partial indexes shine on rare-value predicates.
CREATE INDEX IF NOT EXISTS idx_fact_txn_fraud
    ON curated.fact_transactions (date_key, account_key) WHERE is_fraud;


-- =============================================================================
-- fact_daily_balances — PERIODIC SNAPSHOT
-- GRAIN: exactly one row per account per calendar day.
-- =============================================================================
-- WHY A SNAPSHOT WHEN WE ALREADY HAVE TRANSACTIONS?
-- You COULD compute any day's balance by summing all transactions ever. That is
-- correct but ruinously slow, and it silently breaks for accounts with no
-- activity (no rows = no balance, rather than "same balance as yesterday").
-- A periodic snapshot answers "what was the balance on day X" in one indexed
-- lookup, and it has a row for EVERY account EVERY day, active or not.
-- That "row exists even when nothing happened" property is exactly what makes
-- it a periodic snapshot rather than a transactional fact.
-- =============================================================================
CREATE TABLE IF NOT EXISTS curated.fact_daily_balances (
    balance_key       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_key          INTEGER     NOT NULL REFERENCES curated.dim_date(date_key),
    account_key       BIGINT      NOT NULL REFERENCES curated.dim_account(account_key),
    customer_key      BIGINT      NOT NULL REFERENCES curated.dim_customer(customer_key),

    -- Measures
    closing_balance   NUMERIC(16,2) NOT NULL,
    total_debits      NUMERIC(16,2) NOT NULL DEFAULT 0,
    total_credits     NUMERIC(16,2) NOT NULL DEFAULT 0,
    transaction_count INTEGER       NOT NULL DEFAULT 0,

    load_id           BIGINT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- The grain, enforced by the database: one row per account per day.
    -- A unique constraint on the grain columns is the cheapest possible
    -- protection against a pipeline bug double-loading a day.
    CONSTRAINT uq_daily_balance_grain UNIQUE (date_key, account_key)
);

COMMENT ON TABLE curated.fact_daily_balances IS
    'GRAIN: one row per account per day. Periodic snapshot.';

CREATE INDEX IF NOT EXISTS idx_fact_bal_date ON curated.fact_daily_balances (date_key);
CREATE INDEX IF NOT EXISTS idx_fact_bal_account ON curated.fact_daily_balances (account_key);


-- =============================================================================
-- fact_loan_monthly — PERIODIC SNAPSHOT
-- GRAIN: exactly one row per loan per month.
-- =============================================================================
CREATE TABLE IF NOT EXISTS curated.fact_loan_monthly (
    loan_month_key     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_key           INTEGER  NOT NULL REFERENCES curated.dim_date(date_key),
    loan_id            TEXT     NOT NULL,             -- degenerate dimension
    customer_key       BIGINT   NOT NULL REFERENCES curated.dim_customer(customer_key),
    loan_product_key   BIGINT   NOT NULL REFERENCES curated.dim_loan_product(loan_product_key),

    -- Measures
    outstanding_balance NUMERIC(16,2) NOT NULL,
    scheduled_payment   NUMERIC(16,2) NOT NULL,
    principal_paid      NUMERIC(16,2) NOT NULL DEFAULT 0,
    interest_paid       NUMERIC(16,2) NOT NULL DEFAULT 0,

    -- DOMAIN: days past due drives everything in credit risk reporting.
    -- Banks bucket DPD into 30/60/90+ bands; movement between buckets month to
    -- month is a "roll rate", the standard credit monitoring tool (Sprint 4).
    days_past_due       INTEGER  NOT NULL DEFAULT 0,
    delinquency_bucket  TEXT     NOT NULL DEFAULT 'current',
    is_defaulted        BOOLEAN  NOT NULL DEFAULT FALSE,

    load_id             BIGINT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_loan_month_grain UNIQUE (date_key, loan_id)
);

COMMENT ON TABLE curated.fact_loan_monthly IS
    'GRAIN: one row per loan per month. Periodic snapshot with DPD tracking.';

CREATE INDEX IF NOT EXISTS idx_fact_loan_date ON curated.fact_loan_monthly (date_key);
CREATE INDEX IF NOT EXISTS idx_fact_loan_customer ON curated.fact_loan_monthly (customer_key);
CREATE INDEX IF NOT EXISTS idx_fact_loan_delinquent
    ON curated.fact_loan_monthly (date_key) WHERE days_past_due > 0;
