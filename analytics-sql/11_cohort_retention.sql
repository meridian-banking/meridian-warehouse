-- =============================================================================
-- BUSINESS QUESTION: Of customers who joined in a given month, what share are
--   still transacting N months later?
-- GRAIN OF ANSWER: one row per (join cohort, months since joining)
-- =============================================================================
-- COHORT RETENTION is the standard way to measure whether a business keeps the
-- customers it acquires. The trap it avoids: a simple "how many active customers
-- do we have?" number can look healthy while every individual cohort is
-- collapsing, because new acquisitions mask the churn underneath.
--
-- In banking this drives:
--   - deposit stickiness (how long does acquired money actually stay?)
--   - the value of an acquisition channel (cheap customers who leave in 3 months
--     are worth less than expensive ones who stay 10 years)
--   - lifetime value modelling, which feeds marketing budgets
--
-- THE PATTERN: pin each customer to their cohort, then measure activity by
-- OFFSET FROM THEIR OWN START, not by calendar month. That offset alignment is
-- what makes cohorts comparable.
-- =============================================================================

WITH customer_cohort AS (
    -- Each customer's cohort = the month they joined.
    SELECT
        c.customer_key,
        c.customer_id,
        DATE_TRUNC('month', c.join_date)::date AS cohort_month
    FROM curated.dim_customer c
    WHERE c.is_current AND c.customer_id <> '-1'
),
activity AS (
    -- Every (customer, active month) pair.
    SELECT DISTINCT
        f.customer_key,
        DATE_TRUNC('month', d.full_date)::date AS activity_month
    FROM curated.fact_transactions f
    JOIN curated.dim_date d ON d.date_key = f.date_key
),
cohort_activity AS (
    SELECT
        cc.cohort_month,
        cc.customer_key,
        -- Months elapsed between joining and this activity. This is the
        -- alignment step that makes different cohorts comparable.
        (EXTRACT(YEAR FROM a.activity_month) - EXTRACT(YEAR FROM cc.cohort_month)) * 12
          + (EXTRACT(MONTH FROM a.activity_month) - EXTRACT(MONTH FROM cc.cohort_month))
          AS months_since_join
    FROM customer_cohort cc
    JOIN activity a ON a.customer_key = cc.customer_key
),
cohort_sizes AS (
    SELECT cohort_month, COUNT(DISTINCT customer_key) AS cohort_size
    FROM cohort_activity
    GROUP BY cohort_month
)
SELECT
    ca.cohort_month,
    cs.cohort_size,
    ca.months_since_join::int                          AS month_offset,
    COUNT(DISTINCT ca.customer_key)                    AS active_customers,
    ROUND(100.0 * COUNT(DISTINCT ca.customer_key) / cs.cohort_size, 1) AS retention_pct
FROM cohort_activity ca
JOIN cohort_sizes cs ON cs.cohort_month = ca.cohort_month
WHERE ca.months_since_join BETWEEN 0 AND 12
GROUP BY ca.cohort_month, cs.cohort_size, ca.months_since_join
ORDER BY ca.cohort_month, month_offset
LIMIT 30;
