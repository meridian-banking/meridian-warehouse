-- =============================================================================
-- 004: dim_branch — a small, stable Type 1 dimension
-- =============================================================================
CREATE TABLE IF NOT EXISTS curated.dim_branch (
    branch_key      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_id       TEXT        NOT NULL UNIQUE,
    branch_name     TEXT        NOT NULL,
    city            TEXT,
    state           TEXT,
    region          TEXT,        -- derived from state: a ROLLUP attribute
    opened_date     DATE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- NOTE ON 'region': this is denormalization on purpose.
-- A snowflake schema would put region in a separate dim_region table joined to
-- dim_branch. A STAR schema flattens it into the dimension itself. We choose
-- star because: fewer joins, simpler queries for analysts, and the storage cost
-- of repeating "West" a few thousand times is irrelevant at dimension scale.
-- The classic snowflake argument (avoiding update anomalies) matters far less
-- in a warehouse, where dimensions are rebuilt by a pipeline, not hand-edited.

COMMENT ON TABLE curated.dim_branch IS
    'Branch dimension, SCD Type 1. Grain: one row per branch.';

CREATE INDEX IF NOT EXISTS idx_dim_branch_region ON curated.dim_branch (region);

INSERT INTO curated.dim_branch (branch_id, branch_name)
SELECT '-1', 'Unknown Branch'
WHERE NOT EXISTS (SELECT 1 FROM curated.dim_branch WHERE branch_id = '-1');
