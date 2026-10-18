-- ============================================================
-- Script:   explore_raw_branches.sql
-- Purpose:  Profile raw.branches BEFORE writing its staging procedure
-- Database: banking_delta (schema: raw)
-- Writes:   Only exploration.branches_probe (dropped and rebuilt on every run).
--           raw.branches is never modified.
-- Run: psql -U postgres -d banking_delta -f .\sql\exploration\explore_raw_branches.sql
--      or run it one step at a time in your SQL client and read each result.
--
-- Needs: staging.try_date(TEXT) from 06_sp_load_card_transactions_scd1.sql
-- Key:   branch_id
-- Note:  ifsc_code is checked against the usual 4 letters + 0 + 6 letters or digits format.
--
-- Steps (same flow as explore_raw_customers.sql, each step feeds the next):
--   0  Context
--   1  Structure
--   2  Working set
--   3  Column profile
--   4  Keys
--   5  Categoricals and text
--   6  Dates
--   7  Numerics and flags
--   8  Cross checks
--   9  Metadata
--   10 Rule impact
--
-- Thresholds used below are ASSUMPTIONS, confirm them with the data:
--   opened_date from 1950-01-01 to today
-- ============================================================


-- ============================================================
-- STEP 0: CONTEXT
-- ============================================================

-- 0.1 Size, number of loads, load window
SELECT
    current_database()        AS database_name,
    COUNT(*)                  AS total_rows,
    COUNT(DISTINCT _batch_id) AS batches,
    MIN(_loaded_at)           AS first_loaded,
    MAX(_loaded_at)           AS last_loaded
FROM raw.branches;

-- 0.2 Helper present? (must be TRUE, otherwise run script 06 first)
SELECT to_regprocedure('staging.try_date(text)') IS NOT NULL AS try_date_available;


-- ============================================================
-- STEP 1: STRUCTURE
-- ============================================================

-- 1.1 Columns and declared types (raw columns are often all text)
SELECT
    ordinal_position,
    column_name,
    data_type,
    character_maximum_length,
    is_nullable
FROM information_schema.columns
WHERE table_schema = 'raw'
  AND table_name   = 'branches'
ORDER BY ordinal_position;

-- 1.2 First rows as stored
SELECT *
FROM raw.branches
LIMIT 50;

-- 1.3 Random rows (first rows are rarely representative)
SELECT *
FROM raw.branches
ORDER BY random()
LIMIT 50;


-- ============================================================
-- STEP 2: WORKING SET
-- Parse dates, numbers and flags once; every later step reads this table.
-- Columns: <col>_raw is the stored text, <col> is the parsed value.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS exploration;

DROP TABLE IF EXISTS exploration.branches_probe;

CREATE TABLE exploration.branches_probe AS
SELECT
    c.branch_id::TEXT AS branch_id_raw,
    c.city::TEXT AS city_raw,
    c.state::TEXT AS state_raw,
    c.branch_name::TEXT AS branch_name_raw,
    c.ifsc_code::TEXT AS ifsc_code_raw,
    c.opened_date::TEXT AS opened_date_raw,
    d.opened_date,
    CURRENT_TIMESTAMP AS probed_at
FROM raw.branches c
CROSS JOIN LATERAL (
    SELECT
        staging.try_date(LEFT(TRIM(c.opened_date::TEXT), 10)) AS opened_date
    OFFSET 0
) d;

COMMENT ON TABLE exploration.branches_probe IS
    'Parsed snapshot of raw.branches for data exploration. Rebuilt by explore_raw_branches.sql, safe to drop.';

ANALYZE exploration.branches_probe;


-- ============================================================
-- STEP 3: COLUMN PROFILE (works for every column)
-- null = SQL NULL, blank = empty or spaces, padded = leading/trailing space,
-- placeholder = text such as 'null', 'N/A', 'nan'.
-- ============================================================

-- 3.1 Missing, blank, padded and placeholder values per column
SELECT
    j.key                                                        AS column_name,
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE j.value IS NULL)                      AS null_count,
    COUNT(*) FILTER (WHERE j.value ~ '^\s*$')                    AS blank_count,
    COUNT(*) FILTER (WHERE j.value ~ '^\s|\s$')                  AS padded_count,
    COUNT(*) FILTER (WHERE LOWER(TRIM(j.value)) IN
                     ('null', 'none', 'nan', 'n/a', 'na', 'nil', 'undefined', '-', '?'))
                                                                 AS placeholder_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE j.value IS NULL OR j.value ~ '^\s*$')
          / COUNT(*), 2)                                         AS pct_missing,
    COUNT(DISTINCT j.value)                                      AS distinct_count,
    MIN(LENGTH(j.value))                                         AS min_len,
    MAX(LENGTH(j.value))                                         AS max_len
FROM raw.branches c
CROSS JOIN LATERAL jsonb_each_text(to_jsonb(c)) AS j(key, value)
GROUP BY j.key
ORDER BY pct_missing DESC, column_name;


-- ============================================================
-- STEP 4: KEYS (branch_id and foreign keys)
-- ============================================================

-- 4.1 Key health
SELECT
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE branch_id_raw IS NULL
                        OR TRIM(branch_id_raw) = '')                   AS missing_key,
    COUNT(*) FILTER (WHERE TRIM(branch_id_raw) <> ''
                       AND TRIM(branch_id_raw) !~ '^[0-9]{1,18}$')     AS invalid_format,
    COUNT(DISTINCT TRIM(branch_id_raw))                                AS distinct_keys,
    COUNT(branch_id_raw) - COUNT(DISTINCT TRIM(branch_id_raw))               AS surplus_rows,
    MIN(LENGTH(TRIM(branch_id_raw)))                                   AS min_len,
    MAX(LENGTH(TRIM(branch_id_raw)))                                   AS max_len
FROM exploration.branches_probe;

-- 4.2 Malformed keys (what do they look like?)
SELECT
    branch_id_raw,
    COUNT(*) AS row_count
FROM exploration.branches_probe
WHERE branch_id_raw IS NOT NULL
  AND TRIM(branch_id_raw) !~ '^[0-9]{1,18}$'
GROUP BY branch_id_raw
ORDER BY row_count DESC
LIMIT 50;

-- 4.3 Duplicated keys: harmless reloads or real changes between loads?
WITH per_key AS (
    SELECT
        TRIM(branch_id::TEXT) AS k,
        COUNT(*)        AS copies,
        COUNT(DISTINCT ROW(city, state, branch_name, ifsc_code, opened_date)::TEXT) AS versions
    FROM raw.branches
    WHERE branch_id IS NOT NULL
    GROUP BY 1
)
SELECT
    CASE
        WHEN copies = 1   THEN 'single_row'
        WHEN versions = 1 THEN 'exact_reload'
        ELSE 'changed_between_loads'
    END         AS key_type,
    COUNT(*)    AS keys,
    SUM(copies) AS total_rows,
    MAX(copies) AS max_copies
FROM per_key
GROUP BY 1
ORDER BY keys DESC;

-- 4.4 Five keys whose values changed between loads (spot which columns drift)
WITH changed AS (
    SELECT TRIM(branch_id::TEXT) AS k
    FROM raw.branches
    WHERE branch_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT ROW(city, state, branch_name, ifsc_code, opened_date)::TEXT) > 1
    LIMIT 5
)
SELECT c.*
FROM raw.branches c
JOIN changed ch ON TRIM(c.branch_id::TEXT) = ch.k
ORDER BY ch.k, c._loaded_at;

-- No foreign keys in raw.branches.


-- ============================================================
-- STEP 5: CATEGORICALS AND TEXT
-- Categoricals: values as stored, then the variants that merge after
-- trim + collapse spaces + Title Case (these are the dirty variants).
-- ============================================================

-- 5.1 city: values as stored
SELECT
    COALESCE(city_raw, '<NULL>') AS raw_value,
    COUNT(*)                    AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.branches_probe
GROUP BY city_raw
ORDER BY row_count DESC
LIMIT 100;

-- 5.2 city: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(city_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT city_raw)                                 AS raw_variants,
    array_agg(DISTINCT city_raw)                             AS raw_values,
    COUNT(*)                                                AS row_count
FROM exploration.branches_probe
WHERE city_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT city_raw) > 1
ORDER BY row_count DESC
LIMIT 100;

-- 5.3 state: values as stored
SELECT
    COALESCE(state_raw, '<NULL>') AS raw_value,
    COUNT(*)                    AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.branches_probe
GROUP BY state_raw
ORDER BY row_count DESC
LIMIT 100;

-- 5.4 state: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(state_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT state_raw)                                 AS raw_variants,
    array_agg(DISTINCT state_raw)                             AS raw_values,
    COUNT(*)                                                AS row_count
FROM exploration.branches_probe
WHERE state_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT state_raw) > 1
ORDER BY row_count DESC
LIMIT 100;

-- 5.5 branch_name: profile
SELECT
    'branch_name'                                                         AS column_name,
    COUNT(*)                                                      AS total_rows,
    COUNT(*) FILTER (WHERE branch_name_raw IS NULL OR branch_name_raw ~ '^\s*$')  AS missing,
    COUNT(*) FILTER (WHERE branch_name_raw ~ '^\s|\s$')                   AS padded,
    COUNT(*) FILTER (WHERE branch_name_raw ~ '\s{2,}')                    AS double_spaces,
    MIN(LENGTH(TRIM(branch_name_raw)))                                    AS min_len,
    MAX(LENGTH(TRIM(branch_name_raw)))                                    AS max_len,
    COUNT(DISTINCT branch_name_raw)                                       AS distinct_raw,
    COUNT(DISTINCT LOWER(regexp_replace(TRIM(branch_name_raw), '\s+', ' ', 'g'))) AS distinct_cleaned
FROM exploration.branches_probe;

-- 5.6 branch_name: same value used by different branch_id (cleaned, case insensitive)
SELECT
    LOWER(regexp_replace(TRIM(branch_name_raw), '\s+', ' ', 'g')) AS value_clean,
    COUNT(*)                                              AS row_count,
    COUNT(DISTINCT TRIM(branch_id_raw))                         AS distinct_keys
FROM exploration.branches_probe
WHERE branch_name_raw !~ '^\s*$'
GROUP BY 1
HAVING COUNT(DISTINCT TRIM(branch_id_raw)) > 1
ORDER BY distinct_keys DESC, row_count DESC
LIMIT 50;

-- 5.7 ifsc_code: profile
SELECT
    'ifsc_code'                                                         AS column_name,
    COUNT(*)                                                      AS total_rows,
    COUNT(*) FILTER (WHERE ifsc_code_raw IS NULL OR ifsc_code_raw ~ '^\s*$')  AS missing,
    COUNT(*) FILTER (WHERE ifsc_code_raw ~ '^\s|\s$')                   AS padded,
    COUNT(*) FILTER (WHERE ifsc_code_raw ~ '\s{2,}')                    AS double_spaces,
    MIN(LENGTH(TRIM(ifsc_code_raw)))                                    AS min_len,
    MAX(LENGTH(TRIM(ifsc_code_raw)))                                    AS max_len,
    COUNT(DISTINCT ifsc_code_raw)                                       AS distinct_raw,
    COUNT(DISTINCT LOWER(regexp_replace(TRIM(ifsc_code_raw), '\s+', ' ', 'g'))) AS distinct_cleaned,
    COUNT(*) FILTER (WHERE ifsc_code_raw !~ '^\s*$'
                       AND TRIM(ifsc_code_raw) !~* '^[A-Z]{4}0[A-Z0-9]{6}$') AS invalid_format
FROM exploration.branches_probe;

-- 5.8 ifsc_code: shape of the text (A = capital, a = small, 9 = digit; mixed shapes mean mixed formats)
SELECT
    translate(TRIM(ifsc_code_raw), 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789', 'AAAAAAAAAAAAAAAAAAAAAAAAAAaaaaaaaaaaaaaaaaaaaaaaaaaa9999999999') AS shape,
    COUNT(*)                                   AS row_count,
    MIN(ifsc_code_raw)                               AS example
FROM exploration.branches_probe
WHERE ifsc_code_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC
LIMIT 20;

-- 5.9 ifsc_code: malformed values
SELECT
    ifsc_code_raw,
    COUNT(*) AS row_count
FROM exploration.branches_probe
WHERE ifsc_code_raw !~ '^\s*$'
  AND TRIM(ifsc_code_raw) !~* '^[A-Z]{4}0[A-Z0-9]{6}$'
GROUP BY ifsc_code_raw
ORDER BY row_count DESC
LIMIT 30;

-- 5.10 ifsc_code: same value used by different branch_id (cleaned, case insensitive)
SELECT
    LOWER(regexp_replace(TRIM(ifsc_code_raw), '\s+', ' ', 'g')) AS value_clean,
    COUNT(*)                                              AS row_count,
    COUNT(DISTINCT TRIM(branch_id_raw))                         AS distinct_keys
FROM exploration.branches_probe
WHERE ifsc_code_raw !~ '^\s*$'
GROUP BY 1
HAVING COUNT(DISTINCT TRIM(branch_id_raw)) > 1
ORDER BY distinct_keys DESC, row_count DESC
LIMIT 50;


-- ============================================================
-- STEP 6: DATES
-- ============================================================

-- 6.1 Shape of the raw text (reveals mixed formats and time parts)
SELECT
    'opened_date'        AS column_name,
    translate(TRIM(opened_date_raw), '0123456789', '9999999999') AS shape,
    COUNT(*)     AS row_count,
    MIN(opened_date_raw) AS example_min,
    MAX(opened_date_raw) AS example_max
FROM exploration.branches_probe
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 6.2 Validity and range
SELECT
    'opened_date'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE opened_date_raw IS NULL OR opened_date_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE opened_date_raw !~ '^\s*$' AND opened_date IS NULL)    AS unparsable,
    MIN(opened_date)                                                       AS min_date,
    MAX(opened_date)                                                       AS max_date,
    COUNT(*) FILTER (WHERE opened_date > CURRENT_DATE)                     AS in_future,
    DATE '1950-01-01'                                                    AS min_allowed,
    COUNT(*) FILTER (WHERE opened_date < DATE '1950-01-01')                      AS before_min_allowed
FROM exploration.branches_probe;

-- 6.3 Rows per year
SELECT
    'opened_date'                      AS column_name,
    EXTRACT(YEAR FROM opened_date)::INT AS yr,
    COUNT(*)                   AS row_count
FROM exploration.branches_probe
WHERE opened_date IS NOT NULL
GROUP BY 2
ORDER BY column_name, yr;


-- ============================================================
-- STEP 7: NUMERICS AND FLAGS
-- non_numeric = text that is not a plain number (commas, currency signs, 'k', words).
-- ============================================================

-- No numeric columns in raw.branches.


-- ============================================================
-- STEP 8: CROSS CHECKS (rules that span columns)
-- ============================================================

-- 8.1 City in more than one state (real for some names, a typo signal for others)
SELECT
    INITCAP(TRIM(city_raw))                      AS city,
    COUNT(DISTINCT INITCAP(TRIM(state_raw)))     AS states,
    array_agg(DISTINCT INITCAP(TRIM(state_raw))) AS state_list,
    COUNT(*)                                     AS row_count
FROM exploration.branches_probe
WHERE city_raw IS NOT NULL
  AND state_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT INITCAP(TRIM(state_raw))) > 1
ORDER BY states DESC, row_count DESC
LIMIT 100;

-- 8.2 IFSC bank code (first 4 letters): one bank expected, more means mixed or bad codes
SELECT
    UPPER(LEFT(TRIM(ifsc_code_raw), 4)) AS bank_code,
    COUNT(*)                            AS row_count
FROM exploration.branches_probe
WHERE ifsc_code_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC
LIMIT 50;


-- ============================================================
-- STEP 9: METADATA COLUMNS
-- ============================================================

-- 9.1 One row per load batch
SELECT
    _batch_id,
    COUNT(*)                 AS row_count,
    COUNT(DISTINCT branch_id)      AS distinct_keys,
    MIN(_loaded_at)          AS first_loaded,
    MAX(_loaded_at)          AS last_loaded
FROM raw.branches
GROUP BY _batch_id
ORDER BY first_loaded;

-- 9.2 Shape of the timestamp columns (mixed formats show up as extra rows)
SELECT
    'created_at' AS column_name,
    translate(created_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(created_at::TEXT) AS min_value,
    MAX(created_at::TEXT) AS max_value
FROM raw.branches
GROUP BY 2
UNION ALL
SELECT
    'loaded_at' AS column_name,
    translate(loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(loaded_at::TEXT) AS min_value,
    MAX(loaded_at::TEXT) AS max_value
FROM raw.branches
GROUP BY 2
UNION ALL
SELECT
    '_loaded_at' AS column_name,
    translate(_loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(_loaded_at::TEXT) AS min_value,
    MAX(_loaded_at::TEXT) AS max_value
FROM raw.branches
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 9.3 Keys that appear in more than one batch (drives the dedupe rule)
SELECT COUNT(*) AS keys_in_multiple_batches
FROM (
    SELECT TRIM(branch_id::TEXT)
    FROM raw.branches
    WHERE branch_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT _batch_id) > 1
) x;


-- ============================================================
-- STEP 10: RULE IMPACT
-- Rows each candidate cleaning rule would reject or NULL out.
-- Use this list to decide the rules in the staging procedure.
-- ============================================================

WITH t AS (
    SELECT COUNT(*) AS total FROM exploration.branches_probe
)
SELECT
    r.rule,
    r.failing_rows,
    ROUND(100.0 * r.failing_rows / NULLIF(t.total, 0), 2) AS pct_of_rows
FROM t
CROSS JOIN LATERAL (VALUES
    ('branch_id missing or not 1-18 digits (row would be dropped)',
        (SELECT COUNT(*) FROM exploration.branches_probe WHERE branch_id_raw IS NULL OR TRIM(branch_id_raw) !~ '^[0-9]{1,18}$')),
    ('surplus duplicate rows per branch_id (dedupe removes these)',
        (SELECT COUNT(branch_id_raw) - COUNT(DISTINCT TRIM(branch_id_raw)) FROM exploration.branches_probe)),
    ('opened_date present but not a valid date',
        (SELECT COUNT(*) FROM exploration.branches_probe WHERE opened_date_raw !~ '^\s*$' AND opened_date IS NULL)),
    ('opened_date before 1950-01-01',
        (SELECT COUNT(*) FROM exploration.branches_probe WHERE opened_date < DATE '1950-01-01')),
    ('opened_date in the future',
        (SELECT COUNT(*) FROM exploration.branches_probe WHERE opened_date > CURRENT_DATE)),
    ('ifsc_code present but malformed',
        (SELECT COUNT(*) FROM exploration.branches_probe WHERE ifsc_code_raw !~ '^\s*$' AND TRIM(ifsc_code_raw) !~* '^[A-Z]{4}0[A-Z0-9]{6}$'))
) AS r(rule, failing_rows)
ORDER BY r.failing_rows DESC;
