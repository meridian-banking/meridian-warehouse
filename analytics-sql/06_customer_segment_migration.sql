-- =============================================================================
-- BUSINESS QUESTION: How do customers move between segments over time?
-- GRAIN OF ANSWER: one row per (from_segment, to_segment) pair
-- WHY THIS QUERY EXISTS: it is ONLY possible because of SCD Type 2. With Type 1
--   the old segment is overwritten and this analysis is impossible forever.
--   This is the concrete payoff of the modelling decision.
-- =============================================================================
-- SELF-JOIN on the dimension, matching each version to the one that followed it.

WITH versions AS (
    SELECT
        customer_id,
        segment,
        valid_from,
        valid_to,
        LEAD(segment)    OVER (PARTITION BY customer_id ORDER BY valid_from) AS next_segment,
        LEAD(valid_from) OVER (PARTITION BY customer_id ORDER BY valid_from) AS changed_on
    FROM curated.dim_customer
    WHERE customer_id <> '-1'
)
SELECT
    segment       AS from_segment,
    next_segment  AS to_segment,
    COUNT(*)      AS customers_moved
FROM versions
WHERE next_segment IS NOT NULL
  AND next_segment <> segment
GROUP BY segment, next_segment
ORDER BY customers_moved DESC;
