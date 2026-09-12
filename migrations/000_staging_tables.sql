-- =============================================================================
-- 000: Staging tables — the landing zone inside the warehouse
-- =============================================================================
-- WHY STAGE INSIDE THE DATABASE AT ALL?
-- The loader reads Parquet from the staged lake zone and bulk-copies it into
-- these plain tables first. Then all transformation happens in SQL, inside the
-- database, where it is fast and set-based.
--
-- The alternative — transform in pandas, then insert final rows — pulls millions
-- of rows over the network into Python memory and pushes them back. Staging
-- tables let us "push compute to the data" instead. That phrase is the answer
-- to "why did you do the transformation in SQL rather than Python?"
--
-- These tables are TRUNCATE-and-reload each run: they hold only the current
-- batch, never history. History lives in the curated dimensions.
-- =============================================================================

CREATE TABLE IF NOT EXISTS staging.stg_customers (
    customer_id     TEXT,
    first_name      TEXT,
    last_name       TEXT,
    age             INTEGER,
    annual_income   NUMERIC(14,2),
    credit_score    INTEGER,
    dti             NUMERIC(6,3),
    segment         TEXT,
    join_date       DATE,
    home_branch_id  TEXT
);

CREATE TABLE IF NOT EXISTS staging.stg_accounts (
    account_id      TEXT,
    customer_id     TEXT,
    product_type    TEXT,
    apr             NUMERIC(6,4),
    open_date       DATE,
    status          TEXT,
    initial_balance NUMERIC(16,2)
);

CREATE TABLE IF NOT EXISTS staging.stg_branches (
    branch_id       TEXT,
    branch_name     TEXT,
    city            TEXT,
    state           TEXT,
    opened_date     DATE
);

CREATE TABLE IF NOT EXISTS staging.stg_transactions (
    transaction_id      TEXT,
    account_id          TEXT,
    timestamp           TIMESTAMPTZ,
    amount              NUMERIC(16,2),
    merchant_category   TEXT,
    channel             TEXT,
    is_fraud            BOOLEAN
);

CREATE TABLE IF NOT EXISTS staging.stg_loans (
    loan_id                     TEXT,
    customer_id                 TEXT,
    loan_type                   TEXT,
    principal                   NUMERIC(16,2),
    apr                         NUMERIC(6,4),
    term_months                 INTEGER,
    origination_date            DATE,
    monthly_payment             NUMERIC(16,2),
    credit_score_at_origination INTEGER,
    dti_at_origination          NUMERIC(6,3),
    defaulted                   BOOLEAN
);

-- Staging tables get no indexes and no constraints ON PURPOSE:
-- they are write-once-read-once per batch, and every index would only slow the
-- bulk COPY down for no benefit.
