-- =============================================================================
-- 008: SCD TYPE 2 MERGE — the algorithm at the heart of this sprint
-- =============================================================================
-- This is THE procedure interviewers ask you to walk through. Know the steps.
--
-- THE ALGORITHM, in plain English:
--   Given a batch of incoming customer rows (today's snapshot from staging):
--
--   1. NEW customers          -> insert a row, valid_from = effective date,
--                                valid_to = 9999-12-31, is_current = true
--   2. UNCHANGED customers    -> do nothing at all (this is the common case;
--                                doing nothing is important for performance)
--   3. CHANGED customers      -> close the current row (valid_to = effective
--                                date, is_current = false) AND insert a new
--                                current row
--
-- HOW DO WE DETECT "CHANGED"?
-- We hash the tracked attributes into row_hash and compare hashes. Comparing
-- one hash beats writing `OR src.a IS DISTINCT FROM tgt.a OR src.b IS ...` for
-- ten columns — which is verbose, easy to get wrong, and a nightmare with NULLs.
-- (Note IS DISTINCT FROM, not <>: in SQL, NULL <> NULL is NULL, not true, so a
-- naive <> comparison MISSES changes involving NULLs. Classic interview trap.)
--
-- WHY A STORED PROCEDURE RATHER THAN PYTHON?
-- The merge touches every row of a dimension. Doing it in SQL keeps the data
-- inside the database — no pulling millions of rows over the network into
-- pandas and pushing them back. "Push compute to the data" is the general
-- principle. (We ALSO implement this in Python in the loader, so you can
-- compare the two approaches — that comparison is itself an interview answer.)
-- =============================================================================

-- Helper: compute the hash of tracked attributes.
-- IMMUTABLE tells Postgres this function always returns the same output for the
-- same input, which lets the planner optimize and allows use in indexes.
CREATE OR REPLACE FUNCTION curated.customer_row_hash(
    p_first_name    TEXT,
    p_last_name     TEXT,
    p_age           SMALLINT,
    p_annual_income NUMERIC,
    p_credit_score  SMALLINT,
    p_credit_band   TEXT,
    p_dti           NUMERIC,
    p_segment       TEXT,
    p_home_branch_id TEXT
) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT md5(
        coalesce(p_first_name,     '') || '|' ||
        coalesce(p_last_name,      '') || '|' ||
        coalesce(p_age::text,      '') || '|' ||
        coalesce(p_annual_income::text, '') || '|' ||
        coalesce(p_credit_score::text,  '') || '|' ||
        coalesce(p_credit_band,    '') || '|' ||
        coalesce(p_dti::text,      '') || '|' ||
        coalesce(p_segment,        '') || '|' ||
        coalesce(p_home_branch_id, '')
    );
$$;
-- NOTE the coalesce() on every column: without it, one NULL makes the whole
-- concatenation NULL, so the hash becomes NULL and change detection silently
-- stops working. This is a real bug people ship.


-- =============================================================================
-- The merge procedure. Reads from staging.stg_customers, writes dim_customer.
-- =============================================================================
-- p_initial_load: on the FIRST historical load, dimension rows must be valid
-- from the BEGINNING OF HISTORY, not from today — otherwise no historical fact
-- can ever find a matching version and everything falls to the unknown member.
-- On subsequent incremental runs, new versions are valid from the change date.
-- Getting this wrong is a classic warehouse bootstrapping bug: the model is
-- correct, the merge is correct, and yet every fact joins to 'Unknown'.
CREATE OR REPLACE PROCEDURE curated.merge_dim_customer(
    p_effective_date DATE,
    p_initial_load   BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_closed  INTEGER := 0;
    v_inserted INTEGER := 0;
    v_valid_from DATE := CASE WHEN p_initial_load
                              THEN DATE '1900-01-01'
                              ELSE p_effective_date END;
BEGIN
    -- Stage the incoming batch with its computed hash and derived attributes.
    CREATE TEMP TABLE tmp_incoming ON COMMIT DROP AS
    SELECT
        s.customer_id,
        s.first_name,
        s.last_name,
        s.first_name || ' ' || s.last_name       AS full_name,
        s.age::smallint                          AS age,
        s.annual_income,
        s.credit_score::smallint                 AS credit_score,
        -- DERIVED ATTRIBUTE: credit band. Defined ONCE here, so every report
        -- uses identical boundaries. If each analyst wrote their own CASE,
        -- reports would disagree about who counts as "good credit".
        CASE
            WHEN s.credit_score >= 740 THEN 'excellent'
            WHEN s.credit_score >= 670 THEN 'good'
            WHEN s.credit_score >= 580 THEN 'fair'
            ELSE 'poor'
        END                                      AS credit_band,
        s.dti,
        s.segment,
        s.join_date,
        s.home_branch_id
    FROM staging.stg_customers s;

    ALTER TABLE tmp_incoming ADD COLUMN row_hash TEXT;
    UPDATE tmp_incoming SET row_hash = curated.customer_row_hash(
        first_name, last_name, age, annual_income, credit_score,
        credit_band, dti, segment, home_branch_id
    );

    -- ---- STEP 1: close rows whose tracked attributes changed ----
    WITH changed AS (
        SELECT d.customer_key
        FROM curated.dim_customer d
        JOIN tmp_incoming i ON i.customer_id = d.customer_id
        WHERE d.is_current
          AND d.row_hash IS DISTINCT FROM i.row_hash
    )
    UPDATE curated.dim_customer d
       SET valid_to   = p_effective_date,
           is_current = FALSE,
           updated_at = now()
      FROM changed c
     WHERE d.customer_key = c.customer_key;
    GET DIAGNOSTICS v_closed = ROW_COUNT;

    -- ---- STEP 2: insert new versions (both brand-new and changed customers) ----
    -- After step 1, a changed customer has NO current row, so this single
    -- INSERT handles both cases: never-seen customers and just-closed ones.
    INSERT INTO curated.dim_customer (
        customer_id, first_name, last_name, full_name, age, annual_income,
        credit_score, credit_band, dti, segment, join_date, home_branch_id,
        valid_from, valid_to, is_current, row_hash
    )
    SELECT
        i.customer_id, i.first_name, i.last_name, i.full_name, i.age,
        i.annual_income, i.credit_score, i.credit_band, i.dti, i.segment,
        i.join_date, i.home_branch_id,
        v_valid_from, DATE '9999-12-31', TRUE, i.row_hash
    FROM tmp_incoming i
    WHERE NOT EXISTS (
        SELECT 1 FROM curated.dim_customer d
         WHERE d.customer_id = i.customer_id AND d.is_current
    );
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    RAISE NOTICE 'merge_dim_customer(%, initial=%): closed % rows, inserted % rows',
                 p_effective_date, p_initial_load, v_closed, v_inserted;
END;
$$;

COMMENT ON PROCEDURE curated.merge_dim_customer(DATE, BOOLEAN) IS
    'SCD Type 2 merge for dim_customer. Closes changed rows and inserts new '
    'versions. Idempotent: re-running with unchanged data is a no-op.';
