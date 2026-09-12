-- =============================================================================
-- 001: dim_date — the calendar dimension
-- =============================================================================
-- WHY DOES EVERY WAREHOUSE HAVE A DATE DIMENSION?
-- You could store a raw date on every fact and use SQL date functions. But then
-- every analyst writes their own logic for "is this a business day?", "what
-- fiscal quarter is this?", "is this a holiday?" — and they write it slightly
-- differently, so reports disagree. A date dimension answers those questions
-- ONCE, consistently, for everyone.
--
-- It also makes queries far more readable:
--     WHERE d.is_month_end AND d.fiscal_quarter = 'Q3'
-- beats a pile of EXTRACT() and CASE expressions.
--
-- THE SURROGATE KEY HERE IS SPECIAL: we use YYYYMMDD as an integer
-- (e.g. 20240315). This is the one place a "smart key" is idiomatic — it sorts
-- correctly, is human-readable in raw fact tables, and is compact.
-- =============================================================================

CREATE TABLE IF NOT EXISTS curated.dim_date (
    date_key            INTEGER     PRIMARY KEY,   -- 20240315
    full_date           DATE        NOT NULL UNIQUE,

    -- Calendar parts
    year                SMALLINT    NOT NULL,
    quarter             SMALLINT    NOT NULL,
    month               SMALLINT    NOT NULL,
    month_name          TEXT        NOT NULL,
    week_of_year        SMALLINT    NOT NULL,
    day_of_month        SMALLINT    NOT NULL,
    day_of_week         SMALLINT    NOT NULL,      -- 1=Monday .. 7=Sunday (ISO)
    day_name            TEXT        NOT NULL,

    -- Flags analysts constantly filter on
    is_weekend          BOOLEAN     NOT NULL,
    is_business_day     BOOLEAN     NOT NULL,
    is_month_end        BOOLEAN     NOT NULL,
    is_quarter_end      BOOLEAN     NOT NULL,
    is_year_end         BOOLEAN     NOT NULL,

    -- Fiscal calendar. Many US banks run an Oct-Sep fiscal year; we model that
    -- so "fiscal Q1" means something specific and consistent everywhere.
    fiscal_year         SMALLINT    NOT NULL,
    fiscal_quarter      TEXT        NOT NULL,

    -- Useful for relative-period analysis and rolling windows
    prior_year_date_key INTEGER,
    days_from_epoch     INTEGER     NOT NULL
);

COMMENT ON TABLE curated.dim_date IS
    'Calendar dimension. Grain: one row per calendar date. Key is YYYYMMDD.';

-- Analysts filter on full_date constantly; index it.
CREATE INDEX IF NOT EXISTS idx_dim_date_full_date ON curated.dim_date (full_date);
CREATE INDEX IF NOT EXISTS idx_dim_date_year_month ON curated.dim_date (year, month);
