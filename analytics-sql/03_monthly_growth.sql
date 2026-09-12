-- =============================================================================
-- BUSINESS QUESTION: How is transaction volume growing month over month?
-- GRAIN OF ANSWER: one row per month per segment
-- KPI: MoM growth is a core executive metric on every bank dashboard.
-- =============================================================================
-- PATTERN: aggregate first (CTE), then apply window functions to the aggregate.
-- You cannot use a window function inside the same GROUP BY that produces the
-- aggregate — windows are evaluated AFTER grouping. Hence the two-step CTE.

WITH monthly AS (
    SELECT
        d.year,
        d.month,
        c.segment,
        SUM(f.amount)  AS total_amount,
        COUNT(*)       AS txn_count
    FROM curated.fact_transactions f
    JOIN curated.dim_date d     ON d.date_key = f.date_key
    JOIN curated.dim_customer c ON c.customer_key = f.customer_key
    GROUP BY d.year, d.month, c.segment
)
SELECT
    year,
    month,
    segment,
    total_amount,
    LAG(total_amount) OVER (PARTITION BY segment ORDER BY year, month) AS prior_month,
    ROUND(
        100.0 * (total_amount - LAG(total_amount) OVER (PARTITION BY segment ORDER BY year, month))
        / NULLIF(LAG(total_amount) OVER (PARTITION BY segment ORDER BY year, month), 0),
        2
    ) AS mom_growth_pct
    -- NULLIF guards against divide-by-zero: NULLIF(x,0) returns NULL when x=0,
    -- and dividing by NULL yields NULL rather than raising an error.
FROM monthly
ORDER BY segment, year, month;
