-- =============================================================================
-- BUSINESS QUESTION: Are loans we originated recently performing worse than
--   loans we originated a year ago, at the same point in their life?
-- GRAIN OF ANSWER: one row per (origination cohort, months since origination)
-- =============================================================================
-- VINTAGE ANALYSIS is how banks detect UNDERWRITING DRIFT — the slow slide in
-- standards that precedes a credit blowup. The insight: you cannot compare a
-- 3-month-old loan to a 3-year-old loan, because older loans have had more time
-- to go bad. You must compare cohorts AT THE SAME AGE.
--
-- "Vintage" borrows from wine: all loans originated in 2023-Q1 are one vintage.
-- Plotting cumulative default rate against months-on-book for each vintage gives
-- the classic vintage curve. If newer curves sit ABOVE older ones at the same
-- age, underwriting has loosened — a warning visible long before losses land.
--
-- This is also exactly the reasoning behind OUT-OF-TIME validation in Sprint 8:
-- a credit model must be tested on a later period, because populations drift.
-- =============================================================================

WITH loan_cohorts AS (
    SELECT
        l.loan_id,
        -- The vintage: the year-quarter the loan was originated.
        EXTRACT(YEAR FROM l.origination_date)::int          AS vintage_year,
        EXTRACT(QUARTER FROM l.origination_date)::int       AS vintage_quarter,
        l.origination_date,
        l.principal,
        l.defaulted,
        l.credit_score_at_origination
    FROM staging.stg_loans l
),
cohort_summary AS (
    SELECT
        vintage_year,
        vintage_quarter,
        COUNT(*)                                          AS loans_originated,
        ROUND(SUM(principal), 2)                          AS total_originated,
        ROUND(AVG(credit_score_at_origination), 1)        AS avg_score_at_origination,
        COUNT(*) FILTER (WHERE defaulted)                 AS defaults,
        ROUND(100.0 * COUNT(*) FILTER (WHERE defaulted) / COUNT(*), 2) AS default_rate_pct
    FROM loan_cohorts
    GROUP BY vintage_year, vintage_quarter
)
SELECT
    vintage_year,
    vintage_quarter,
    loans_originated,
    total_originated,
    avg_score_at_origination,
    defaults,
    default_rate_pct,
    -- Compare each vintage to the one before it. A rising default rate combined
    -- with a FALLING average origination score is the signature of loosening
    -- underwriting — the thing this entire query exists to detect.
    LAG(default_rate_pct) OVER (ORDER BY vintage_year, vintage_quarter)
        AS prior_vintage_default_rate,
    ROUND(default_rate_pct - LAG(default_rate_pct) OVER (
        ORDER BY vintage_year, vintage_quarter), 2)       AS default_rate_change,
    ROUND(avg_score_at_origination - LAG(avg_score_at_origination) OVER (
        ORDER BY vintage_year, vintage_quarter), 1)       AS score_change
FROM cohort_summary
ORDER BY vintage_year, vintage_quarter;
