-- =============================================================================
-- 005: dim_merchant_category — a tiny lookup dimension
-- =============================================================================
-- Only ~10 rows. Worth its own dimension anyway, because it carries derived
-- attributes (is_discretionary, risk tier) that analysts group by and that we
-- want defined in exactly ONE place rather than re-derived in every query.
-- =============================================================================
CREATE TABLE IF NOT EXISTS curated.dim_merchant_category (
    merchant_category_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_code         TEXT    NOT NULL UNIQUE,
    category_name         TEXT    NOT NULL,
    is_discretionary      BOOLEAN NOT NULL,   -- wants vs needs
    fraud_risk_tier       TEXT    NOT NULL,   -- low / medium / high
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE curated.dim_merchant_category IS
    'Merchant category lookup. Grain: one row per category code.';

INSERT INTO curated.dim_merchant_category
    (category_code, category_name, is_discretionary, fraud_risk_tier)
VALUES
    ('grocery',        'Grocery',            FALSE, 'low'),
    ('restaurant',     'Restaurant',         TRUE,  'low'),
    ('gas',            'Fuel',               FALSE, 'medium'),
    ('retail',         'Retail',             TRUE,  'medium'),
    ('online',         'Online / E-commerce',TRUE,  'high'),
    ('utilities',      'Utilities',          FALSE, 'low'),
    ('travel',         'Travel',             TRUE,  'high'),
    ('healthcare',     'Healthcare',         FALSE, 'low'),
    ('entertainment',  'Entertainment',      TRUE,  'medium'),
    ('atm_withdrawal', 'ATM Withdrawal',     FALSE, 'medium'),
    ('unknown',        'Unknown',            FALSE, 'medium')
ON CONFLICT (category_code) DO NOTHING;
