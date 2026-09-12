-- =============================================================================
-- BUSINESS QUESTION: Where is fraud concentrated?
-- GRAIN OF ANSWER: one row per merchant category
-- WHY: Fraud ops need to know where to focus review capacity. Rate matters more
--      than raw count — a category with few transactions but high fraud RATE is
--      more actionable than a high-volume category with normal rates.
-- =============================================================================
-- FILTER clause: the SQL-standard conditional aggregate. Cleaner and often
-- faster than SUM(CASE WHEN ... THEN 1 ELSE 0 END).

SELECT
    mc.category_name,
    mc.fraud_risk_tier,
    COUNT(*)                                   AS total_txns,
    COUNT(*) FILTER (WHERE f.is_fraud)         AS fraud_txns,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_fraud) / COUNT(*), 4) AS fraud_rate_pct,
    ROUND(SUM(f.amount) FILTER (WHERE f.is_fraud), 2)              AS fraud_amount,
    ROUND(AVG(f.amount) FILTER (WHERE f.is_fraud), 2)              AS avg_fraud_amount,
    ROUND(AVG(f.amount) FILTER (WHERE NOT f.is_fraud), 2)          AS avg_normal_amount
FROM curated.fact_transactions f
JOIN curated.dim_merchant_category mc ON mc.merchant_category_key = f.merchant_category_key
GROUP BY mc.category_name, mc.fraud_risk_tier
ORDER BY fraud_rate_pct DESC;
