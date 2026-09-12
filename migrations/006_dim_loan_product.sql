-- =============================================================================
-- 006: dim_loan_product — loan product lookup
-- =============================================================================
CREATE TABLE IF NOT EXISTS curated.dim_loan_product (
    loan_product_key  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_type         TEXT    NOT NULL UNIQUE,
    product_name      TEXT    NOT NULL,
    is_secured        BOOLEAN NOT NULL,   -- backed by collateral?
    typical_term_months SMALLINT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- DOMAIN NOTE: 'secured' means the loan is backed by an asset the bank can
-- seize on default (a car, a house). Secured loans carry LOWER interest rates
-- precisely because the bank's loss given default (LGD) is lower — it can
-- recover value. This shows up again in Sprint 8's expected-loss modelling:
--     Expected Loss = PD x LGD x EAD
COMMENT ON TABLE curated.dim_loan_product IS
    'Loan product lookup. Grain: one row per loan type.';

INSERT INTO curated.dim_loan_product
    (loan_type, product_name, is_secured, typical_term_months)
VALUES
    ('auto',     'Auto Loan',      TRUE,  60),
    ('mortgage', 'Mortgage',       TRUE,  360),
    ('personal', 'Personal Loan',  FALSE, 36),
    ('student',  'Student Loan',   FALSE, 120),
    ('unknown',  'Unknown',        FALSE, NULL)
ON CONFLICT (loan_type) DO NOTHING;
