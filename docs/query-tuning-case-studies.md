# Query Tuning Case Studies

Real `EXPLAIN (ANALYZE, BUFFERS)` measurements against the Meridian warehouse. Each case states the query, the plan before and after, the change made, and the measured result.

> **How to read a plan, briefly.** Postgres prints a tree, read **innermost-first**. Each node shows `cost=startup..total` (the planner's *estimate*, in arbitrary units) and `actual time=startup..total rows=N loops=N` (what really happened). The two most valuable habits: (1) compare estimated `rows` to actual `rows` — a large gap means the planner's statistics are stale and it is choosing badly; (2) look for `Rows Removed by Filter` — a big number means you read data you did not need.

---

## Case 1 — Fraud lookup: partial index vs sequential scan

**Query.** Count and sum fraudulent transactions in Q1 2022 — the kind of thing a fraud-ops dashboard runs constantly.

```sql
SELECT count(*), sum(amount)
FROM curated.fact_transactions
WHERE is_fraud AND date_key BETWEEN 20220101 AND 20220331;
```

**Before — no index on the fraud predicate:**

```
Finalize Aggregate  (actual time=28.537..28.666 rows=1)
  ->  Gather
        ->  Partial Aggregate
              ->  Parallel Seq Scan on fact_transactions  (actual time=0.213..22.527)
                    Filter: (is_fraud AND (date_key >= 20220101) AND (date_key <= 20220331))
                    Rows Removed by Filter: 99880
Execution Time: 28.689 ms
```

The tell is `Rows Removed by Filter: 99880`. Postgres read essentially the whole table and discarded 99.8% of it. It even parallelised the scan, which makes the query faster but does not make it *correct* in approach — it is brute force applied efficiently.

**The change.** A **partial index** — one that only indexes rows matching a predicate:

```sql
CREATE INDEX idx_fact_txn_fraud
    ON curated.fact_transactions (date_key, account_key)
    WHERE is_fraud;
```

**After:**

```
Aggregate  (actual time=0.810..0.812 rows=1)
  ->  Bitmap Heap Scan on fact_transactions  (actual time=0.057..0.752)
        ->  Bitmap Index Scan on idx_fact_txn_fraud  (actual time=0.036..0.036)
              Index Cond: ((date_key >= 20220101) AND (date_key <= 20220331))
Execution Time: 0.871 ms
```

**Result: 28.689 ms → 0.871 ms, a 33× improvement.**

**Why a *partial* index specifically.** Fraud is ~0.15% of rows. A full index on `is_fraud` would contain an entry for all 300,000 rows, of which 299,550 say "false" and are never searched for. The partial index contains only the ~450 fraud rows: it is roughly 600× smaller, fits trivially in cache, and costs almost nothing to maintain on insert because most inserts do not qualify.

**The general rule to state in an interview:** partial indexes win when queries consistently filter on a *rare* value of a column. If you were querying `WHERE NOT is_fraud`, the partial index would be useless and a sequential scan would genuinely be the right plan.

---

## Case 2 — Join strategy: why the planner picks what it picks

Postgres has three join algorithms and chooses between them by cost:

| Algorithm | How it works | Wins when |
|---|---|---|
| **Nested Loop** | For each row on the left, look up matches on the right | The left side is tiny and the right side is indexed |
| **Hash Join** | Build a hash table from the smaller side, probe with the larger | Both sides are large, no useful index, equality join |
| **Merge Join** | Sort both sides, walk them in step | Both inputs are already sorted (often by an index) |

Observed on a fact-to-dimension join in this warehouse: joining 300,000 facts to 2,001 customer rows produces a **Hash Join** — Postgres builds a hash table from the small dimension and streams the large fact table past it. That is the textbook-correct choice, and it is the shape almost every star-schema query takes. This is a practical reason star schemas perform well: small dimensions hash cheaply.

**When it goes wrong.** If statistics are stale and the planner *thinks* a table has 50 rows when it has 5 million, it may choose a Nested Loop and the query will hang. The fix is `ANALYZE <table>`, and the diagnostic is the estimated-vs-actual row gap in the plan.

---

## Case 3 — Stale statistics

Postgres decides plans using sampled statistics, refreshed by autovacuum. After a bulk load, statistics can lag badly — the planner may believe a freshly-loaded table is still empty.

```sql
ANALYZE curated.fact_transactions;
```

**In an interview, "my query suddenly got slow" should be investigated in this order:**

1. `EXPLAIN ANALYZE` it — do not guess
2. Compare estimated vs actual rows — a large gap means stale stats → `ANALYZE`
3. Look for `Seq Scan` with a high `Rows Removed by Filter` → index opportunity
4. Check whether the data volume genuinely grew (a plan that was fine at 10k rows may be wrong at 10M)
5. Check for a changed parameter or a newly non-selective filter
6. Only then consider partitioning, denormalisation, or hardware

Reaching for hardware first is the classic junior mistake. The plan tells you the answer.

---

## Index strategy in this warehouse, and the reasoning

| Index | Type | Why |
|---|---|---|
| `idx_fact_txn_date` | B-tree | Nearly every analytical query filters or groups by date |
| `idx_fact_txn_account`, `idx_fact_txn_customer` | B-tree | Join performance to the large dimensions |
| `idx_fact_txn_fraud` | **Partial** | Fraud is a rare value; see Case 1 |
| `uq_dim_customer_current` | **Partial unique** | Enforces at most one current SCD2 row per customer |
| `idx_dim_customer_pit` | B-tree composite | Point-in-time lookups `(customer_id, valid_from, valid_to)` |

**The cost side, which candidates often forget to mention:** every index must be updated on every insert, update, and delete, and consumes storage and cache. Indexes are not free. The right number is "enough to serve the queries you actually run, and no more" — which is why index decisions should follow from measured plans, not from adding one to every column just in case.

---

## BRIN: the index type worth knowing about for large facts

For very large, append-only, naturally date-ordered tables, a **BRIN** (Block Range INdex) stores only the min/max value per block range rather than an entry per row. It is dramatically smaller than a B-tree — kilobytes instead of gigabytes — and works well *precisely because* rows arrive in date order, so each block range covers a narrow date span.

```sql
CREATE INDEX idx_fact_txn_date_brin
    ON curated.fact_transactions USING BRIN (date_key);
```

Not used by default here because at 300k rows a B-tree is entirely adequate. The trade-off to state: BRIN is far cheaper to store and maintain, but only effective when physical row order correlates with the indexed column. Shuffle the data and BRIN becomes useless while a B-tree keeps working.
