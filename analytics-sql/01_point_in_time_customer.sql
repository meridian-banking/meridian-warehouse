-- =============================================================================
-- BUSINESS QUESTION: What was a customer's credit profile on a specific date?
-- GRAIN OF ANSWER: one row per customer
-- WHY IT MATTERS: This is the fair-lending / audit question. When we made a
--   decision about this customer, what did we actually know?
-- =============================================================================
-- THE PATTERN: date >= valid_from AND date < valid_to
-- Half-open interval [valid_from, valid_to). Guarantees exactly one match:
-- no gaps, no overlaps, no double counting at boundaries.

SELECT
    customer_id,
    full_name,
    segment,
    credit_score,
    credit_band,
    valid_from,
    valid_to
FROM curated.dim_customer
WHERE customer_id = :customer_id
  AND :as_of_date >= valid_from
  AND :as_of_date <  valid_to;
