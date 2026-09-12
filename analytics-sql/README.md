# Analytical SQL Library

Documented, tested queries against the Meridian warehouse. Each file states its **business question** and the **grain of its answer** before any SQL — the two things that should be settled before writing a query.

## Foundations

| File | Question | Techniques |
|---|---|---|
| `01_point_in_time_customer.sql` | What was a customer's credit profile on a given date? | SCD2 half-open interval |
| `02_running_balance.sql` | How does an account balance move over time? | `SUM() OVER`, `LAG` |
| `03_monthly_growth.sql` | How is volume growing month over month? | CTE + `LAG`, `NULLIF` guard |
| `04_top_customers_per_segment.sql` | Top N customers within each segment? | `ROW_NUMBER` partitioned |
| `05_fraud_rate_by_dimension.sql` | Where is fraud concentrated? | `FILTER` conditional aggregation |
| `06_customer_segment_migration.sql` | How do customers move between segments? | `LEAD` over SCD2 history |

## Sprint 4 additions

| File | Question | Techniques |
|---|---|---|
| `07_window_functions_tour.sql` | Guided tour of every window function | All ranking/offset/aggregate windows, frames, named `WINDOW` |
| `08_delinquency_roll_rate.sql` | What share of 30-DPD loans roll to 60 DPD? | `LAG` on snapshots, nested `SUM(COUNT(*)) OVER` |
| `09_vintage_analysis.sql` | Are recent loan cohorts underperforming older ones at the same age? | Cohorting, `LAG` comparisons |
| `10_gaps_and_islands.sql` | Longest streak of consecutive active days? | The `date - ROW_NUMBER()` island trick |
| `11_cohort_retention.sql` | What share of a join cohort is still active N months later? | Cohort offset alignment |
| `12_interview_classics.sql` | The standard SQL screen questions | Nth-highest, dedup, `NOT EXISTS` vs `NOT IN`, pivots, percentiles |

## Why these specific queries

Each maps to something a bank actually does:

- **Roll rates** forecast charge-offs and set loan loss provisions. A static delinquency number tells you where you are; a roll rate tells you where you're *headed*.
- **Vintage analysis** detects underwriting drift — the slow loosening of standards that precedes a credit blowup. It's also the reasoning behind out-of-time model validation in Sprint 8.
- **Cohort retention** measures deposit stickiness and acquisition-channel value, and avoids the trap where new customers mask churn in a headline "active customers" number.
- **Gaps and islands** underpins dormancy detection, which banks are required to perform.
- **Percentiles over averages** matter because transaction amounts are log-normal: the mean ($80) sits 57% above the median ($51) and describes almost nobody.

## Tuning

See [`../docs/query-tuning-case-studies.md`](../docs/query-tuning-case-studies.md) for `EXPLAIN (ANALYZE, BUFFERS)` evidence, including a measured **33× improvement** (28.7 ms → 0.87 ms) from a partial index on the fraud predicate.
