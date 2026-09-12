-- =============================================================================
-- BUSINESS QUESTION: Who are the top 5 customers by spend within each segment?
-- GRAIN OF ANSWER: one row per customer (top 5 per segment)
-- =============================================================================
-- RANKING FUNCTIONS — know the difference cold, it is a guaranteed question:
--   ROW_NUMBER() -> 1,2,3,4  always unique, arbitrary tiebreak
--   RANK()       -> 1,2,2,4  ties share a rank, then SKIPS
--   DENSE_RANK() -> 1,2,2,3  ties share a rank, no skip
-- Use ROW_NUMBER for "exactly N rows"; DENSE_RANK for "top N values including
-- ties"; RANK when competition-style gaps are wanted.

WITH customer_spend AS (
    SELECT
        c.customer_id,
        c.full_name,
        c.segment,
        SUM(f.amount) AS total_spend,
        COUNT(*)      AS txn_count
    FROM curated.fact_transactions f
    JOIN curated.dim_customer c ON c.customer_key = f.customer_key
    WHERE c.customer_id <> '-1'
    GROUP BY c.customer_id, c.full_name, c.segment
),
ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY segment ORDER BY total_spend DESC) AS rn
    FROM customer_spend
)
SELECT customer_id, full_name, segment, total_spend, txn_count, rn AS rank_in_segment
FROM ranked
WHERE rn <= 5
ORDER BY segment, rn;
