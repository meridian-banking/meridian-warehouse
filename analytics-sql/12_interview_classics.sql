-- =============================================================================
-- THE STANDARD SQL SCREEN QUESTIONS, solved against the Meridian warehouse.
-- =============================================================================
-- Every one of these appears in real SQL interviews. Solving them against your
-- own banking schema — rather than a toy `employees` table — means you can
-- answer with "here's how I did that on my platform", which lands far better.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Nth HIGHEST VALUE (the most-asked SQL question in existence)
--    "Find the 3rd highest transaction amount per account."
-- -----------------------------------------------------------------------------
-- WHY DENSE_RANK AND NOT ROW_NUMBER OR RANK:
--   ROW_NUMBER breaks ties arbitrarily — with duplicate amounts you would get an
--     essentially random pick, and "3rd highest" becomes non-deterministic.
--   RANK skips after ties (1,2,2,4), so rank 3 might not exist at all.
--   DENSE_RANK (1,2,2,3) gives the 3rd distinct VALUE, which is what the
--     question actually means.
-- Being able to explain that distinction IS the interview answer.
SELECT account_id, amount, dr AS dense_rank
FROM (
    SELECT a.account_id, f.amount,
           DENSE_RANK() OVER (PARTITION BY f.account_key ORDER BY f.amount DESC) AS dr
    FROM curated.fact_transactions f
    JOIN curated.dim_account a ON a.account_key = f.account_key
) ranked
WHERE dr = 3
ORDER BY account_id
LIMIT 10;


-- -----------------------------------------------------------------------------
-- 2. DEDUPLICATION — keep one row per key, drop the rest
--    "If the same transaction were ingested twice, keep only the earliest."
-- -----------------------------------------------------------------------------
-- The canonical pattern: ROW_NUMBER() partitioned by the key you want unique,
-- ordered by your tiebreaker, then keep rn = 1. Here ROW_NUMBER is exactly
-- right (unlike question 1) because we want precisely one row, ties or not.
SELECT transaction_id, account_key, amount, transaction_ts
FROM (
    SELECT f.*,
           ROW_NUMBER() OVER (PARTITION BY f.transaction_id
                              ORDER BY f.created_at, f.transaction_key) AS rn
    FROM curated.fact_transactions f
) d
WHERE rn = 1
LIMIT 5;


-- -----------------------------------------------------------------------------
-- 3. FIRST AND LAST EVENT PER ENTITY
--    "What was each customer's first and most recent transaction?"
-- -----------------------------------------------------------------------------
-- Two valid approaches, and knowing both is worth stating:
--   (a) window functions — one pass, flexible, shown here
--   (b) DISTINCT ON (Postgres-specific) — shorter but less portable
SELECT
    customer_id,
    MIN(transaction_ts)                                              AS first_txn,
    MAX(transaction_ts)                                              AS last_txn,
    (MAX(transaction_ts)::date - MIN(transaction_ts)::date)          AS days_active,
    COUNT(*)                                                         AS total_txns
FROM curated.fact_transactions f
JOIN curated.dim_customer c ON c.customer_key = f.customer_key
WHERE c.customer_id <> '-1'
GROUP BY customer_id
ORDER BY total_txns DESC
LIMIT 10;


-- -----------------------------------------------------------------------------
-- 4. THE NULL TRAP: NOT IN vs NOT EXISTS
--    "Which accounts have never had a fraudulent transaction?"
-- -----------------------------------------------------------------------------
-- THIS IS A FAVOURITE INTERVIEW TRAP.
--   NOT IN (subquery) returns NO ROWS AT ALL if the subquery yields a single
--   NULL. Why? `x NOT IN (1, NULL)` evaluates to `x<>1 AND x<>NULL`, and
--   `x<>NULL` is NULL (unknown), so the whole expression can never be TRUE.
--   NOT EXISTS handles NULLs correctly and is usually faster (it can
--   short-circuit on the first match).
-- RULE: default to NOT EXISTS. Reach for NOT IN only over a provably non-null
-- column, and say so out loud in an interview.
SELECT a.account_id, a.product_type
FROM curated.dim_account a
WHERE NOT EXISTS (
    SELECT 1 FROM curated.fact_transactions f
    WHERE f.account_key = a.account_key AND f.is_fraud
)
AND a.account_id <> '-1'
ORDER BY a.account_id
LIMIT 10;


-- -----------------------------------------------------------------------------
-- 5. CONDITIONAL AGGREGATION / PIVOT
--    "Show transaction counts by channel as COLUMNS, not rows."
-- -----------------------------------------------------------------------------
-- FILTER is the SQL-standard form and is cleaner than SUM(CASE WHEN...).
-- Postgres supports both; FILTER reads better and is often marginally faster.
SELECT
    c.segment,
    COUNT(*)                                              AS total_txns,
    COUNT(*) FILTER (WHERE f.channel = 'online')          AS online_txns,
    COUNT(*) FILTER (WHERE f.channel = 'in_person')       AS in_person_txns,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.channel = 'online') / COUNT(*), 1)
                                                          AS pct_online,
    ROUND(AVG(f.amount) FILTER (WHERE f.channel = 'online'), 2)    AS avg_online_amt,
    ROUND(AVG(f.amount) FILTER (WHERE f.channel = 'in_person'), 2) AS avg_in_person_amt
FROM curated.fact_transactions f
JOIN curated.dim_customer c ON c.customer_key = f.customer_key
WHERE c.customer_id <> '-1'
GROUP BY c.segment
ORDER BY total_txns DESC;


-- -----------------------------------------------------------------------------
-- 6. PERCENTILES — a real distribution, not just an average
--    "What does the transaction amount distribution look like per segment?"
-- -----------------------------------------------------------------------------
-- WHY THIS MATTERS: averages lie on skewed data. Transaction amounts are
-- log-normal (right-skewed), so the mean sits well above the median and
-- describes almost nobody. Percentiles describe the actual shape.
-- PERCENTILE_CONT interpolates between rows; PERCENTILE_DISC returns an actual
-- observed value. Use CONT for continuous measures like money.
SELECT
    c.segment,
    COUNT(*)                                                          AS n,
    ROUND(AVG(f.amount), 2)                                           AS mean,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY f.amount)::numeric, 2) AS median,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY f.amount)::numeric, 2) AS p90,
    ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY f.amount)::numeric, 2) AS p99,
    ROUND(MAX(f.amount), 2)                                           AS max
FROM curated.fact_transactions f
JOIN curated.dim_customer c ON c.customer_key = f.customer_key
WHERE c.customer_id <> '-1'
GROUP BY c.segment
ORDER BY n DESC;
