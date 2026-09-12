-- =============================================================================
-- BUSINESS QUESTION: Of loans that were 30 days past due last month, what
--   percentage rolled forward to 60 days past due this month?
-- GRAIN OF ANSWER: one row per (from_bucket, to_bucket) transition per month
-- =============================================================================
-- WHY THIS IS THE MOST IMPORTANT CREDIT-RISK QUERY IN BANKING:
--
-- A roll rate measures MOMENTUM in a loan book. A static "3% of loans are
-- delinquent" tells you where you are; a roll rate tells you where you are
-- HEADED. If the 30->60 roll rate jumps from 20% to 35%, losses are coming in
-- two months even though today's delinquency number looks normal.
--
-- Banks use roll rates to:
--   - forecast charge-offs (loans written off as uncollectable)
--   - set loan loss provisions (money reserved against expected losses)
--   - trigger collections strategy changes
--
-- DPD BUCKETS (days past due) are the industry-standard ladder:
--   current -> 1-29 -> 30-59 -> 60-89 -> 90+ -> charge-off
-- A loan at 90+ DPD is usually considered "in default" for regulatory purposes.
--
-- THE SQL PATTERN: self-join a monthly snapshot to itself, offset by one month.
-- LAG() over the loan's month-ordered history gives us "last month's bucket"
-- without an explicit self-join, which is cleaner and usually faster.
-- =============================================================================

WITH monthly_status AS (
    SELECT
        f.loan_id,
        d.year,
        d.month,
        f.delinquency_bucket,
        f.outstanding_balance,
        -- The same loan's bucket in the PREVIOUS monthly snapshot.
        LAG(f.delinquency_bucket) OVER (
            PARTITION BY f.loan_id ORDER BY d.year, d.month
        ) AS prior_bucket,
        LAG(f.outstanding_balance) OVER (
            PARTITION BY f.loan_id ORDER BY d.year, d.month
        ) AS prior_balance
    FROM curated.fact_loan_monthly f
    JOIN curated.dim_date d ON d.date_key = f.date_key
)
SELECT
    year,
    month,
    prior_bucket                                  AS from_bucket,
    delinquency_bucket                            AS to_bucket,
    COUNT(*)                                      AS loan_count,
    ROUND(SUM(prior_balance), 2)                  AS balance_at_risk,
    -- The roll rate itself: of everything that WAS in from_bucket, what share
    -- landed in to_bucket? The denominator is the whole from_bucket cohort,
    -- which is why we need a window SUM over the partition.
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (
        PARTITION BY year, month, prior_bucket
    ), 2)                                         AS roll_rate_pct
FROM monthly_status
WHERE prior_bucket IS NOT NULL
GROUP BY year, month, prior_bucket, delinquency_bucket
ORDER BY year, month, prior_bucket, delinquency_bucket;

-- NOTE the nested aggregate + window: SUM(COUNT(*)) OVER (...).
-- COUNT(*) is computed first by the GROUP BY, then the window SUM runs over
-- those already-aggregated rows. Windows are evaluated AFTER grouping, which is
-- exactly why this works and why you cannot use a window inside the GROUP BY.
