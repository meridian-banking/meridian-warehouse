-- =============================================================================
-- BUSINESS QUESTION: Find each account's longest streak of consecutive days
--   with activity, and detect accounts that have gone dormant.
-- GRAIN OF ANSWER: one row per (account, streak)
-- =============================================================================
-- "GAPS AND ISLANDS" is a named SQL pattern and a guaranteed interview question.
--   ISLANDS = runs of consecutive values (active days in a row)
--   GAPS    = the breaks between them (periods of inactivity)
--
-- Banking uses: activity streaks, dormancy detection (regulators require banks
-- to identify and escheat dormant accounts), consecutive months of delinquency,
-- and continuous-employment checks in underwriting.
--
-- THE CLASSIC TRICK, and you should be able to explain WHY it works:
--   Take the date, and subtract ROW_NUMBER() ordered by that same date.
--   For CONSECUTIVE dates, both increase by exactly 1 each row, so the
--   difference is CONSTANT. When a gap appears, the date jumps but the row
--   number does not, so the difference changes. That constant value therefore
--   identifies the island — group by it and each group is one streak.
--
--   date        row_num   date - row_num   <- constant within a streak
--   2024-01-01     1        2023-12-31
--   2024-01-02     2        2023-12-31     same island
--   2024-01-03     3        2023-12-31     same island
--   2024-01-07     4        2024-01-03     NEW island (gap of 3 days)
-- =============================================================================

WITH daily_activity AS (
    -- One row per account per day that had ANY transaction.
    SELECT DISTINCT
        f.account_key,
        d.full_date
    FROM curated.fact_transactions f
    JOIN curated.dim_date d ON d.date_key = f.date_key
),
numbered AS (
    SELECT
        account_key,
        full_date,
        ROW_NUMBER() OVER (PARTITION BY account_key ORDER BY full_date) AS rn
    FROM daily_activity
),
islands AS (
    SELECT
        account_key,
        full_date,
        -- The grouping key: constant within a run of consecutive days.
        full_date - (rn || ' days')::interval AS island_key
    FROM numbered
)
SELECT
    a.account_id,
    MIN(i.full_date)                                   AS streak_start,
    MAX(i.full_date)                                   AS streak_end,
    COUNT(*)                                           AS consecutive_days,
    (MAX(i.full_date) - MIN(i.full_date)) + 1          AS span_check  -- sanity: should equal consecutive_days
FROM islands i
JOIN curated.dim_account a ON a.account_key = i.account_key
GROUP BY a.account_id, i.island_key
HAVING COUNT(*) >= 5          -- only streaks of 5+ consecutive active days
ORDER BY consecutive_days DESC, a.account_id
LIMIT 15;
