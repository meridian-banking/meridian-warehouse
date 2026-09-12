-- =============================================================================
-- BUSINESS QUESTION: What is the running account balance over time?
-- GRAIN OF ANSWER: one row per transaction, with cumulative balance
-- =============================================================================
-- WINDOW FUNCTION: SUM() OVER (PARTITION BY ... ORDER BY ...)
-- A window function computes across a set of rows RELATED to the current row,
-- without collapsing them the way GROUP BY does. That is the key difference:
--   GROUP BY -> many rows in, few rows out
--   WINDOW   -> many rows in, SAME many rows out, each with an extra value
--
-- The default frame with ORDER BY is RANGE BETWEEN UNBOUNDED PRECEDING AND
-- CURRENT ROW — i.e. "everything up to and including me" — which is exactly
-- what a running total needs.

SELECT
    a.account_id,
    d.full_date,
    f.amount,
    SUM(f.amount) OVER (
        PARTITION BY f.account_key
        ORDER BY f.transaction_ts
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total,
    -- LAG looks at the PREVIOUS row in the window. Classic use: change vs prior.
    LAG(f.amount) OVER (
        PARTITION BY f.account_key ORDER BY f.transaction_ts
    ) AS prior_amount
FROM curated.fact_transactions f
JOIN curated.dim_account a ON a.account_key = f.account_key
JOIN curated.dim_date d    ON d.date_key = f.date_key
ORDER BY a.account_id, f.transaction_ts;
