-- =============================================================================
-- BUSINESS QUESTION: A guided tour of every window function, on one dataset.
-- GRAIN OF ANSWER: one row per transaction (windows PRESERVE rows)
-- =============================================================================
-- THE CORE DISTINCTION, which everything in this sprint builds on:
--
--   GROUP BY  : many rows in -> FEW rows out.  It COLLAPSES.
--   WINDOW    : many rows in -> SAME many out. It ADDS A COLUMN.
--
-- If you ever want "every row, plus some context computed across related rows",
-- that is a window function. GROUP BY cannot do it without a self-join.
--
-- ANATOMY:
--   FUNCTION() OVER (
--       PARTITION BY <cols>   -- reset the calculation per group (optional)
--       ORDER BY <cols>       -- define ordering; required for ranking/offset fns
--       <frame>               -- which rows around me are included (optional)
--   )
-- =============================================================================

SELECT
    a.account_id,
    d.full_date,
    f.amount,

    -- ---- RANKING FUNCTIONS (need ORDER BY, ignore frames) ----
    -- ROW_NUMBER : 1,2,3,4  always unique; ties broken arbitrarily
    -- RANK       : 1,2,2,4  ties share a rank, then SKIP
    -- DENSE_RANK : 1,2,2,3  ties share a rank, no skip
    ROW_NUMBER() OVER w                       AS txn_seq,
    RANK()       OVER (PARTITION BY f.account_key ORDER BY f.amount DESC) AS amount_rank,
    DENSE_RANK() OVER (PARTITION BY f.account_key ORDER BY f.amount DESC) AS amount_dense_rank,

    -- NTILE(4) splits rows into 4 roughly equal buckets = quartiles.
    -- Useful for "which quartile of spend is this customer in?"
    NTILE(4) OVER (PARTITION BY f.account_key ORDER BY f.amount) AS amount_quartile,

    -- ---- OFFSET FUNCTIONS: look at OTHER rows without a self-join ----
    LAG(f.amount)  OVER w  AS prev_amount,   -- the row before me
    LEAD(f.amount) OVER w  AS next_amount,   -- the row after me
    f.amount - LAG(f.amount) OVER w AS change_from_prev,

    -- FIRST_VALUE / LAST_VALUE: the extremes of the window.
    -- WATCH OUT: LAST_VALUE with a default frame gives the CURRENT row, not the
    -- true last row, because the default frame ends at CURRENT ROW. You must
    -- widen the frame explicitly — a classic interview gotcha.
    FIRST_VALUE(f.amount) OVER w AS first_txn_amount,
    LAST_VALUE(f.amount) OVER (
        PARTITION BY f.account_key ORDER BY f.transaction_ts
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS last_txn_amount,

    -- ---- AGGREGATES AS WINDOWS (the most useful category) ----
    -- Running total: frame = everything up to and including me
    SUM(f.amount) OVER (
        PARTITION BY f.account_key ORDER BY f.transaction_ts
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total,

    -- Moving average over the last 7 transactions (me + 6 before)
    ROUND(AVG(f.amount) OVER (
        PARTITION BY f.account_key ORDER BY f.transaction_ts
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 2) AS moving_avg_7,

    -- Whole-partition aggregate (no ORDER BY => frame is the entire partition).
    -- This is how you get "this row's share of the account total".
    ROUND(100.0 * f.amount / SUM(f.amount) OVER (PARTITION BY f.account_key), 4)
        AS pct_of_account_total

FROM curated.fact_transactions f
JOIN curated.dim_account a ON a.account_key = f.account_key
JOIN curated.dim_date d    ON d.date_key = f.date_key
-- Naming the window once with WINDOW avoids repeating the OVER clause and is
-- both cleaner and a small signal of SQL fluency.
WINDOW w AS (PARTITION BY f.account_key ORDER BY f.transaction_ts)
ORDER BY a.account_id, f.transaction_ts
LIMIT 20;
