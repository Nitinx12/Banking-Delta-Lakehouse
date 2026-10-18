-- ============================================================
-- Script:   explore_raw_loans.sql
-- Purpose:  Profile raw.loans BEFORE writing its staging procedure
-- Database: banking_delta (schema: raw)
-- Writes:   Only exploration.loans_probe (dropped and rebuilt on every run).
--           raw.loans is never modified.
-- Run: psql -U postgres -d banking_delta -f .\sql\exploration\explore_raw_loans.sql
--      or run it one step at a time in your SQL client and read each result.
--
-- Needs: staging.try_date(TEXT) from 06_sp_load_card_transactions_scd1.sql
-- Key:   loan_id
-- Note:  Ranges match 07_sp_load_loans_scd1.sql: rate 0 to 100, term 1 to 600 months.
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
--   start_date from 2000-01-01 to today
--   loan_amount greater than 0
--   interest_rate between 0 and 100
--   term_months between 1 and 600, whole numbers
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
FROM raw.loans;

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
  AND table_name   = 'loans'
ORDER BY ordinal_position;

-- 1.2 First rows as stored
SELECT *
FROM raw.loans
LIMIT 50;

-- 1.3 Random rows (first rows are rarely representative)
SELECT *
FROM raw.loans
ORDER BY random()
LIMIT 50;


-- ============================================================
-- STEP 2: WORKING SET
-- Parse dates, numbers and flags once; every later step reads this table.
-- Columns: <col>_raw is the stored text, <col> is the parsed value.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS exploration;

DROP TABLE IF EXISTS exploration.loans_probe;

CREATE TABLE exploration.loans_probe AS
SELECT
    c.loan_id::TEXT AS loan_id_raw,
    c.customer_id::TEXT AS customer_id_raw,
    c.branch_id::TEXT AS branch_id_raw,
    c.loan_type::TEXT AS loan_type_raw,
    c.status::TEXT AS status_raw,
    c.start_date::TEXT AS start_date_raw,
    c.loan_amount::TEXT AS loan_amount_raw,
    c.interest_rate::TEXT AS interest_rate_raw,
    c.term_months::TEXT AS term_months_raw,
    d.start_date,
    n.loan_amount,
    n.interest_rate,
    n.term_months,
    CURRENT_TIMESTAMP AS probed_at
FROM raw.loans c
CROSS JOIN LATERAL (
    SELECT
        staging.try_date(LEFT(TRIM(c.start_date::TEXT), 10)) AS start_date
    OFFSET 0
) d
CROSS JOIN LATERAL (
    SELECT
        CASE WHEN TRIM(c.loan_amount::TEXT) ~ '^-?[0-9]+(\.[0-9]+)?$'
             THEN TRIM(c.loan_amount::TEXT)::NUMERIC END AS loan_amount,
        CASE WHEN TRIM(c.interest_rate::TEXT) ~ '^-?[0-9]+(\.[0-9]+)?$'
             THEN TRIM(c.interest_rate::TEXT)::NUMERIC END AS interest_rate,
        CASE WHEN TRIM(c.term_months::TEXT) ~ '^-?[0-9]+(\.[0-9]+)?$'
             THEN TRIM(c.term_months::TEXT)::NUMERIC END AS term_months
    OFFSET 0
) n;

COMMENT ON TABLE exploration.loans_probe IS
    'Parsed snapshot of raw.loans for data exploration. Rebuilt by explore_raw_loans.sql, safe to drop.';

ANALYZE exploration.loans_probe;


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
FROM raw.loans c
CROSS JOIN LATERAL jsonb_each_text(to_jsonb(c)) AS j(key, value)
GROUP BY j.key
ORDER BY pct_missing DESC, column_name;


-- ============================================================
-- STEP 4: KEYS (loan_id and foreign keys)
-- ============================================================

-- 4.1 Key health
SELECT
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE loan_id_raw IS NULL
                        OR TRIM(loan_id_raw) = '')                   AS missing_key,
    COUNT(*) FILTER (WHERE TRIM(loan_id_raw) <> ''
                       AND TRIM(loan_id_raw) !~ '^[0-9]{1,18}$')     AS invalid_format,
    COUNT(DISTINCT TRIM(loan_id_raw))                                AS distinct_keys,
    COUNT(loan_id_raw) - COUNT(DISTINCT TRIM(loan_id_raw))               AS surplus_rows,
    MIN(LENGTH(TRIM(loan_id_raw)))                                   AS min_len,
    MAX(LENGTH(TRIM(loan_id_raw)))                                   AS max_len
FROM exploration.loans_probe;

-- 4.2 Malformed keys (what do they look like?)
SELECT
    loan_id_raw,
    COUNT(*) AS row_count
FROM exploration.loans_probe
WHERE loan_id_raw IS NOT NULL
  AND TRIM(loan_id_raw) !~ '^[0-9]{1,18}$'
GROUP BY loan_id_raw
ORDER BY row_count DESC
LIMIT 50;

-- 4.3 Duplicated keys: harmless reloads or real changes between loads?
WITH per_key AS (
    SELECT
        TRIM(loan_id::TEXT) AS k,
        COUNT(*)        AS copies,
        COUNT(DISTINCT ROW(customer_id, branch_id, loan_type, status, start_date, loan_amount, interest_rate, term_months)::TEXT) AS versions
    FROM raw.loans
    WHERE loan_id IS NOT NULL
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
    SELECT TRIM(loan_id::TEXT) AS k
    FROM raw.loans
    WHERE loan_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT ROW(customer_id, branch_id, loan_type, status, start_date, loan_amount, interest_rate, term_months)::TEXT) > 1
    LIMIT 5
)
SELECT c.*
FROM raw.loans c
JOIN changed ch ON TRIM(c.loan_id::TEXT) = ch.k
ORDER BY ch.k, c._loaded_at;

-- 4.5 Foreign keys: missing, malformed, and ids with no parent row in raw
SELECT
    'customer_id'                                                       AS fk_column,
    'raw.customers.customer_id'                                              AS parent,
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE p.customer_id_raw IS NULL
                        OR TRIM(p.customer_id_raw) = '')                AS missing,
    COUNT(*) FILTER (WHERE TRIM(p.customer_id_raw) <> ''
                       AND TRIM(p.customer_id_raw) !~ '^[0-9]{1,18}$')  AS invalid_format,
    COUNT(*) FILTER (WHERE TRIM(p.customer_id_raw) ~ '^[0-9]{1,18}$'
                       AND r.id IS NULL)                         AS orphan_rows,
    COUNT(DISTINCT TRIM(p.customer_id_raw)) FILTER (WHERE TRIM(p.customer_id_raw) ~ '^[0-9]{1,18}$'
                                                AND r.id IS NULL) AS orphan_distinct_ids
FROM exploration.loans_probe p
LEFT JOIN (
    SELECT DISTINCT TRIM(customer_id::TEXT) AS id
    FROM raw.customers
) r ON r.id = TRIM(p.customer_id_raw)
UNION ALL
SELECT
    'branch_id'                                                       AS fk_column,
    'raw.branches.branch_id'                                              AS parent,
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE p.branch_id_raw IS NULL
                        OR TRIM(p.branch_id_raw) = '')                AS missing,
    COUNT(*) FILTER (WHERE TRIM(p.branch_id_raw) <> ''
                       AND TRIM(p.branch_id_raw) !~ '^[0-9]{1,18}$')  AS invalid_format,
    COUNT(*) FILTER (WHERE TRIM(p.branch_id_raw) ~ '^[0-9]{1,18}$'
                       AND r.id IS NULL)                         AS orphan_rows,
    COUNT(DISTINCT TRIM(p.branch_id_raw)) FILTER (WHERE TRIM(p.branch_id_raw) ~ '^[0-9]{1,18}$'
                                                AND r.id IS NULL) AS orphan_distinct_ids
FROM exploration.loans_probe p
LEFT JOIN (
    SELECT DISTINCT TRIM(branch_id::TEXT) AS id
    FROM raw.branches
) r ON r.id = TRIM(p.branch_id_raw);


-- ============================================================
-- STEP 5: CATEGORICALS AND TEXT
-- Categoricals: values as stored, then the variants that merge after
-- trim + collapse spaces + Title Case (these are the dirty variants).
-- ============================================================

-- 5.1 loan_type: values as stored
SELECT
    COALESCE(loan_type_raw, '<NULL>') AS raw_value,
    COUNT(*)                    AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.loans_probe
GROUP BY loan_type_raw
ORDER BY row_count DESC
LIMIT 100;

-- 5.2 loan_type: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(loan_type_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT loan_type_raw)                                 AS raw_variants,
    array_agg(DISTINCT loan_type_raw)                             AS raw_values,
    COUNT(*)                                                AS row_count
FROM exploration.loans_probe
WHERE loan_type_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT loan_type_raw) > 1
ORDER BY row_count DESC
LIMIT 100;

-- 5.3 status: values as stored
SELECT
    COALESCE(status_raw, '<NULL>') AS raw_value,
    COUNT(*)                    AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.loans_probe
GROUP BY status_raw
ORDER BY row_count DESC
LIMIT 100;

-- 5.4 status: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(status_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT status_raw)                                 AS raw_variants,
    array_agg(DISTINCT status_raw)                             AS raw_values,
    COUNT(*)                                                AS row_count
FROM exploration.loans_probe
WHERE status_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT status_raw) > 1
ORDER BY row_count DESC
LIMIT 100;


-- ============================================================
-- STEP 6: DATES
-- ============================================================

-- 6.1 Shape of the raw text (reveals mixed formats and time parts)
SELECT
    'start_date'        AS column_name,
    translate(TRIM(start_date_raw), '0123456789', '9999999999') AS shape,
    COUNT(*)     AS row_count,
    MIN(start_date_raw) AS example_min,
    MAX(start_date_raw) AS example_max
FROM exploration.loans_probe
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 6.2 Validity and range
SELECT
    'start_date'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE start_date_raw IS NULL OR start_date_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE start_date_raw !~ '^\s*$' AND start_date IS NULL)    AS unparsable,
    MIN(start_date)                                                       AS min_date,
    MAX(start_date)                                                       AS max_date,
    COUNT(*) FILTER (WHERE start_date > CURRENT_DATE)                     AS in_future,
    DATE '2000-01-01'                                                    AS min_allowed,
    COUNT(*) FILTER (WHERE start_date < DATE '2000-01-01')                      AS before_min_allowed
FROM exploration.loans_probe;

-- 6.3 Rows per year
SELECT
    'start_date'                      AS column_name,
    EXTRACT(YEAR FROM start_date)::INT AS yr,
    COUNT(*)                   AS row_count
FROM exploration.loans_probe
WHERE start_date IS NOT NULL
GROUP BY 2
ORDER BY column_name, yr;


-- ============================================================
-- STEP 7: NUMERICS AND FLAGS
-- non_numeric = text that is not a plain number (commas, currency signs, 'k', words).
-- ============================================================

-- 7.1 loan_amount: profile
SELECT
    'loan_amount'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE loan_amount_raw IS NULL OR loan_amount_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE loan_amount_raw !~ '^\s*$' AND loan_amount IS NULL)    AS non_numeric,
    COUNT(*) FILTER (WHERE loan_amount < 0)                                AS negative,
    COUNT(*) FILTER (WHERE loan_amount = 0)                                AS zero,
    MIN(loan_amount)                                                       AS min_value,
    MAX(loan_amount)                                                       AS max_value,
    ROUND(AVG(loan_amount), 2)                                             AS avg_value,
    ROUND(STDDEV(loan_amount), 2)                                          AS stddev_value,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY loan_amount)              AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY loan_amount)              AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY loan_amount)              AS p75,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY loan_amount)              AS p99,
    MAX(LENGTH(SPLIT_PART(TRIM(loan_amount_raw), '.', 2)))                 AS max_decimals
FROM exploration.loans_probe;

-- 7.2 loan_amount: the text values that are not numbers
SELECT
    loan_amount_raw,
    COUNT(*) AS row_count
FROM exploration.loans_probe
WHERE loan_amount_raw !~ '^\s*$'
  AND loan_amount IS NULL
GROUP BY loan_amount_raw
ORDER BY row_count DESC
LIMIT 50;

-- 7.3 loan_amount: outlier fences (IQR rule on positive values)
WITH q AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY loan_amount) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY loan_amount) AS q3
    FROM exploration.loans_probe
    WHERE loan_amount > 0
)
SELECT
    q.q1,
    q.q3,
    q.q3 - q.q1                                   AS iqr,
    q.q1 - 1.5 * (q.q3 - q.q1)                    AS lower_fence,
    q.q3 + 1.5 * (q.q3 - q.q1)                    AS upper_fence,
    (SELECT COUNT(*) FROM exploration.loans_probe p
     WHERE p.loan_amount > q.q3 + 1.5 * (q.q3 - q.q1))    AS rows_above_fence
FROM q;

-- 7.4 loan_amount: order of magnitude (spots unit mix ups)
SELECT
    FLOOR(LOG(loan_amount))::INT AS power_of_10,
    COUNT(*)             AS row_count,
    MIN(loan_amount)             AS min_value,
    MAX(loan_amount)             AS max_value
FROM exploration.loans_probe
WHERE loan_amount > 0
GROUP BY 1
ORDER BY 1;

-- 7.5 loan_amount: extremes
(SELECT 'highest' AS side, loan_id_raw, loan_amount FROM exploration.loans_probe
 WHERE loan_amount IS NOT NULL ORDER BY loan_amount DESC LIMIT 20)
UNION ALL
(SELECT 'lowest', loan_id_raw, loan_amount FROM exploration.loans_probe
 WHERE loan_amount IS NOT NULL ORDER BY loan_amount ASC LIMIT 20);

-- 7.6 interest_rate: profile
SELECT
    'interest_rate'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE interest_rate_raw IS NULL OR interest_rate_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE interest_rate_raw !~ '^\s*$' AND interest_rate IS NULL)    AS non_numeric,
    COUNT(*) FILTER (WHERE interest_rate < 0)                                AS negative,
    COUNT(*) FILTER (WHERE interest_rate = 0)                                AS zero,
    MIN(interest_rate)                                                       AS min_value,
    MAX(interest_rate)                                                       AS max_value,
    ROUND(AVG(interest_rate), 2)                                             AS avg_value,
    ROUND(STDDEV(interest_rate), 2)                                          AS stddev_value,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY interest_rate)              AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY interest_rate)              AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY interest_rate)              AS p75,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY interest_rate)              AS p99,
    MAX(LENGTH(SPLIT_PART(TRIM(interest_rate_raw), '.', 2)))                 AS max_decimals,
    COUNT(*) FILTER (WHERE interest_rate < 0 OR interest_rate > 100) AS outside_expected_range
FROM exploration.loans_probe;

-- 7.7 interest_rate: the text values that are not numbers
SELECT
    interest_rate_raw,
    COUNT(*) AS row_count
FROM exploration.loans_probe
WHERE interest_rate_raw !~ '^\s*$'
  AND interest_rate IS NULL
GROUP BY interest_rate_raw
ORDER BY row_count DESC
LIMIT 50;

-- 7.8 interest_rate: outlier fences (IQR rule on positive values)
WITH q AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY interest_rate) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY interest_rate) AS q3
    FROM exploration.loans_probe
    WHERE interest_rate > 0
)
SELECT
    q.q1,
    q.q3,
    q.q3 - q.q1                                   AS iqr,
    q.q1 - 1.5 * (q.q3 - q.q1)                    AS lower_fence,
    q.q3 + 1.5 * (q.q3 - q.q1)                    AS upper_fence,
    (SELECT COUNT(*) FROM exploration.loans_probe p
     WHERE p.interest_rate > q.q3 + 1.5 * (q.q3 - q.q1))    AS rows_above_fence
FROM q;

-- 7.9 interest_rate: extremes
(SELECT 'highest' AS side, loan_id_raw, interest_rate FROM exploration.loans_probe
 WHERE interest_rate IS NOT NULL ORDER BY interest_rate DESC LIMIT 20)
UNION ALL
(SELECT 'lowest', loan_id_raw, interest_rate FROM exploration.loans_probe
 WHERE interest_rate IS NOT NULL ORDER BY interest_rate ASC LIMIT 20);

-- 7.10 term_months: profile
SELECT
    'term_months'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE term_months_raw IS NULL OR term_months_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE term_months_raw !~ '^\s*$' AND term_months IS NULL)    AS non_numeric,
    COUNT(*) FILTER (WHERE term_months < 0)                                AS negative,
    COUNT(*) FILTER (WHERE term_months = 0)                                AS zero,
    MIN(term_months)                                                       AS min_value,
    MAX(term_months)                                                       AS max_value,
    ROUND(AVG(term_months), 2)                                             AS avg_value,
    ROUND(STDDEV(term_months), 2)                                          AS stddev_value,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY term_months)              AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY term_months)              AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY term_months)              AS p75,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY term_months)              AS p99,
    MAX(LENGTH(SPLIT_PART(TRIM(term_months_raw), '.', 2)))                 AS max_decimals,
    COUNT(*) FILTER (WHERE term_months <> TRUNC(term_months)) AS non_integer,
    COUNT(*) FILTER (WHERE term_months < 1 OR term_months > 600) AS outside_expected_range
FROM exploration.loans_probe;

-- 7.11 term_months: the text values that are not numbers
SELECT
    term_months_raw,
    COUNT(*) AS row_count
FROM exploration.loans_probe
WHERE term_months_raw !~ '^\s*$'
  AND term_months IS NULL
GROUP BY term_months_raw
ORDER BY row_count DESC
LIMIT 50;

-- 7.12 term_months: outlier fences (IQR rule on positive values)
WITH q AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY term_months) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY term_months) AS q3
    FROM exploration.loans_probe
    WHERE term_months > 0
)
SELECT
    q.q1,
    q.q3,
    q.q3 - q.q1                                   AS iqr,
    q.q1 - 1.5 * (q.q3 - q.q1)                    AS lower_fence,
    q.q3 + 1.5 * (q.q3 - q.q1)                    AS upper_fence,
    (SELECT COUNT(*) FROM exploration.loans_probe p
     WHERE p.term_months > q.q3 + 1.5 * (q.q3 - q.q1))    AS rows_above_fence
FROM q;

-- 7.13 term_months: extremes
(SELECT 'highest' AS side, loan_id_raw, term_months FROM exploration.loans_probe
 WHERE term_months IS NOT NULL ORDER BY term_months DESC LIMIT 20)
UNION ALL
(SELECT 'lowest', loan_id_raw, term_months FROM exploration.loans_probe
 WHERE term_months IS NOT NULL ORDER BY term_months ASC LIMIT 20);


-- ============================================================
-- STEP 8: CROSS CHECKS (rules that span columns)
-- ============================================================

-- 8.1 loan_amount by loan_type (do the groups make sense?)
SELECT
    INITCAP(regexp_replace(TRIM(loan_type_raw), '\s+', ' ', 'g')) AS loan_type,
    COUNT(*)                                                  AS row_count,
    COUNT(loan_amount)                                               AS numeric_rows,
    MIN(loan_amount)                                                 AS min_value,
    ROUND(AVG(loan_amount), 2)                                       AS avg_value,
    MAX(loan_amount)                                                 AS max_value
FROM exploration.loans_probe
WHERE loan_type_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC;

-- 8.2 interest_rate by loan_type (do the groups make sense?)
SELECT
    INITCAP(regexp_replace(TRIM(loan_type_raw), '\s+', ' ', 'g')) AS loan_type,
    COUNT(*)                                                  AS row_count,
    COUNT(interest_rate)                                               AS numeric_rows,
    MIN(interest_rate)                                                 AS min_value,
    ROUND(AVG(interest_rate), 2)                                       AS avg_value,
    MAX(interest_rate)                                                 AS max_value
FROM exploration.loans_probe
WHERE loan_type_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC;

-- 8.3 term_months by loan_type (do the groups make sense?)
SELECT
    INITCAP(regexp_replace(TRIM(loan_type_raw), '\s+', ' ', 'g')) AS loan_type,
    COUNT(*)                                                  AS row_count,
    COUNT(term_months)                                               AS numeric_rows,
    MIN(term_months)                                                 AS min_value,
    ROUND(AVG(term_months), 2)                                       AS avg_value,
    MAX(term_months)                                                 AS max_value
FROM exploration.loans_probe
WHERE loan_type_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC;

-- 8.4 loan_amount by status (do the groups make sense?)
SELECT
    INITCAP(regexp_replace(TRIM(status_raw), '\s+', ' ', 'g')) AS status,
    COUNT(*)                                                  AS row_count,
    COUNT(loan_amount)                                               AS numeric_rows,
    MIN(loan_amount)                                                 AS min_value,
    ROUND(AVG(loan_amount), 2)                                       AS avg_value,
    MAX(loan_amount)                                                 AS max_value
FROM exploration.loans_probe
WHERE status_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC;

-- 8.5 Loan type against status
SELECT
    INITCAP(regexp_replace(TRIM(loan_type_raw), '[\s_\-]+', ' ', 'g')) AS loan_type,
    INITCAP(regexp_replace(TRIM(status_raw), '[\s_\-]+', ' ', 'g'))    AS status,
    COUNT(*)                                                             AS row_count
FROM exploration.loans_probe
GROUP BY 1, 2
ORDER BY 1, row_count DESC;


-- ============================================================
-- STEP 9: METADATA COLUMNS
-- ============================================================

-- 9.1 One row per load batch
SELECT
    _batch_id,
    COUNT(*)                 AS row_count,
    COUNT(DISTINCT loan_id)      AS distinct_keys,
    MIN(_loaded_at)          AS first_loaded,
    MAX(_loaded_at)          AS last_loaded
FROM raw.loans
GROUP BY _batch_id
ORDER BY first_loaded;

-- 9.2 Shape of the timestamp columns (mixed formats show up as extra rows)
SELECT
    'created_at' AS column_name,
    translate(created_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(created_at::TEXT) AS min_value,
    MAX(created_at::TEXT) AS max_value
FROM raw.loans
GROUP BY 2
UNION ALL
SELECT
    'loaded_at' AS column_name,
    translate(loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(loaded_at::TEXT) AS min_value,
    MAX(loaded_at::TEXT) AS max_value
FROM raw.loans
GROUP BY 2
UNION ALL
SELECT
    '_loaded_at' AS column_name,
    translate(_loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(_loaded_at::TEXT) AS min_value,
    MAX(_loaded_at::TEXT) AS max_value
FROM raw.loans
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 9.3 Keys that appear in more than one batch (drives the dedupe rule)
SELECT COUNT(*) AS keys_in_multiple_batches
FROM (
    SELECT TRIM(loan_id::TEXT)
    FROM raw.loans
    WHERE loan_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT _batch_id) > 1
) x;


-- ============================================================
-- STEP 10: RULE IMPACT
-- Rows each candidate cleaning rule would reject or NULL out.
-- Use this list to decide the rules in the staging procedure.
-- ============================================================

WITH t AS (
    SELECT COUNT(*) AS total FROM exploration.loans_probe
)
SELECT
    r.rule,
    r.failing_rows,
    ROUND(100.0 * r.failing_rows / NULLIF(t.total, 0), 2) AS pct_of_rows
FROM t
CROSS JOIN LATERAL (VALUES
    ('loan_id missing or not 1-18 digits (row would be dropped)',
        (SELECT COUNT(*) FROM exploration.loans_probe WHERE loan_id_raw IS NULL OR TRIM(loan_id_raw) !~ '^[0-9]{1,18}$')),
    ('surplus duplicate rows per loan_id (dedupe removes these)',
        (SELECT COUNT(loan_id_raw) - COUNT(DISTINCT TRIM(loan_id_raw)) FROM exploration.loans_probe)),
    ('customer_id present but not 1-18 digits',
        (SELECT COUNT(*) FROM exploration.loans_probe WHERE TRIM(customer_id_raw) <> '' AND TRIM(customer_id_raw) !~ '^[0-9]{1,18}$')),
    ('customer_id has no parent row in raw.customers',
        (SELECT COUNT(*) FROM exploration.loans_probe p WHERE TRIM(p.customer_id_raw) ~ '^[0-9]{1,18}$' AND NOT EXISTS (SELECT 1 FROM raw.customers r WHERE TRIM(r.customer_id::TEXT) = TRIM(p.customer_id_raw)))),
    ('branch_id present but not 1-18 digits',
        (SELECT COUNT(*) FROM exploration.loans_probe WHERE TRIM(branch_id_raw) <> '' AND TRIM(branch_id_raw) !~ '^[0-9]{1,18}$')),
    ('branch_id has no parent row in raw.branches',
        (SELECT COUNT(*) FROM exploration.loans_probe p WHERE TRIM(p.branch_id_raw) ~ '^[0-9]{1,18}$' AND NOT EXISTS (SELECT 1 FROM raw.branches r WHERE TRIM(r.branch_id::TEXT) = TRIM(p.branch_id_raw)))),
    ('start_date present but not a valid date',
        (SELECT COUNT(*) FROM exploration.loans_probe WHERE start_date_raw !~ '^\s*$' AND start_date IS NULL)),
    ('start_date before 2000-01-01',
        (SELECT COUNT(*) FROM exploration.loans_probe WHERE start_date < DATE '2000-01-01')),
    ('start_date in the future',
        (SELECT COUNT(*) FROM exploration.loans_probe WHERE start_date > CURRENT_DATE)),
    ('loan_amount present but not numeric',
        (SELECT COUNT(*) FROM exploration.loans_probe WHERE loan_amount_raw !~ '^\s*$' AND loan_amount IS NULL)),
    ('loan_amount zero or negative',
        (SELECT COUNT(*) FROM exploration.loans_probe WHERE loan_amount <= 0)),
    ('interest_rate present but not numeric',
        (SELECT COUNT(*) FROM exploration.loans_probe WHERE interest_rate_raw !~ '^\s*$' AND interest_rate IS NULL)),
    ('interest_rate outside 0 to 100',
        (SELECT COUNT(*) FROM exploration.loans_probe WHERE interest_rate < 0 OR interest_rate > 100)),
    ('term_months present but not numeric',
        (SELECT COUNT(*) FROM exploration.loans_probe WHERE term_months_raw !~ '^\s*$' AND term_months IS NULL)),
    ('term_months outside 1 to 600',
        (SELECT COUNT(*) FROM exploration.loans_probe WHERE term_months < 1 OR term_months > 600)),
    ('term_months not a whole number',
        (SELECT COUNT(*) FROM exploration.loans_probe WHERE term_months <> TRUNC(term_months)))
) AS r(rule, failing_rows)
ORDER BY r.failing_rows DESC;
