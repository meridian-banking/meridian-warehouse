-- =============================================================================
-- 003: dim_account — SCD Type 1 (deliberately different from dim_customer)
-- =============================================================================
-- WHY TYPE 1 HERE BUT TYPE 2 FOR CUSTOMER?
-- This is a real modeling judgement call, and interviewers like it.
-- Type 2 costs storage and query complexity. You pay that cost only where
-- history has ANALYTICAL or REGULATORY value.
--   - Customer segment/credit band: history matters enormously (fair lending,
--     underwriting drift, point-in-time reporting) -> Type 2.
--   - Account product type and APR: these effectively never change for an
--     existing account, and nobody asks "what was this account's APR in 2022?"
--     -> Type 1 is sufficient and cheaper.
-- The rule: track history where someone will actually ASK about history.
-- =============================================================================

CREATE TABLE IF NOT EXISTS curated.dim_account (
    account_key     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id      TEXT        NOT NULL UNIQUE,   -- natural key
    customer_id     TEXT        NOT NULL,          -- natural FK to customer
    product_type    TEXT        NOT NULL,
    product_family  TEXT        NOT NULL,          -- deposit vs credit (derived)
    apr             NUMERIC(6,4),
    open_date       DATE,
    status          TEXT,
    initial_balance NUMERIC(16,2),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE curated.dim_account IS
    'Account dimension, SCD Type 1. Grain: one row per account.';

CREATE INDEX IF NOT EXISTS idx_dim_account_customer ON curated.dim_account (customer_id);
CREATE INDEX IF NOT EXISTS idx_dim_account_product ON curated.dim_account (product_type);

-- Unknown member (same reasoning as dim_customer).
INSERT INTO curated.dim_account (account_id, customer_id, product_type, product_family)
SELECT '-1', '-1', 'unknown', 'unknown'
WHERE NOT EXISTS (SELECT 1 FROM curated.dim_account WHERE account_id = '-1');
