-- ============================================================
-- Script:   explore_raw_loan_payments.sql
-- Purpose:  Profile raw.loan_payments BEFORE writing its staging procedure
-- Database: banking_delta (schema: raw)
-- Writes:   Only exploration.loan_payments_probe (dropped and rebuilt on every run).
--           raw.loan_payments is never modified.
-- Run: psql -U postgres -d banking_delta -f .\sql\exploration\explore_raw_loan_payments.sql
--      or run it one step at a time in your SQL client and read each result.
--
-- Needs: staging.try_date(TEXT) from 06_sp_load_card_transactions_scd1.sql
-- Key:   payment_id
-- Note:  Mirrors the maths in 08_sp_load_loan_payments_scd1.sql.
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
--   payment_date from 2000-01-01 to today
--   amount_paid greater than 0
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
FROM raw.loan_payments;

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
  AND table_name   = 'loan_payments'
ORDER BY ordinal_position;

-- 1.2 First rows as stored
SELECT *
FROM raw.loan_payments
LIMIT 50;

-- 1.3 Random rows (first rows are rarely representative)
SELECT *
FROM raw.loan_payments
ORDER BY random()
LIMIT 50;


-- ============================================================
-- STEP 2: WORKING SET
-- Parse dates, numbers and flags once; every later step reads this table.
-- Columns: <col>_raw is the stored text, <col> is the parsed value.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS exploration;

DROP TABLE IF EXISTS exploration.loan_payments_probe;

CREATE TABLE exploration.loan_payments_probe AS
SELECT
    c.payment_id::TEXT AS payment_id_raw,
    c.loan_id::TEXT AS loan_id_raw,
    c.payment_date::TEXT AS payment_date_raw,
    c.amount_paid::TEXT AS amount_paid_raw,
    c.principal_component::TEXT AS principal_component_raw,
    c.interest_component::TEXT AS interest_component_raw,
    c.late_payment_flag::TEXT AS late_payment_flag_raw,
    d.payment_date,
    n.amount_paid,
    n.principal_component,
    n.interest_component,
    CASE
        WHEN LOWER(TRIM(c.late_payment_flag::TEXT)) IN ('1', 'true', 't', 'yes', 'y') THEN TRUE
        WHEN LOWER(TRIM(c.late_payment_flag::TEXT)) IN ('0', 'false', 'f', 'no', 'n') THEN FALSE
    END AS late_payment_flag,
    CURRENT_TIMESTAMP AS probed_at
FROM raw.loan_payments c
CROSS JOIN LATERAL (
    SELECT
        staging.try_date(LEFT(TRIM(c.payment_date::TEXT), 10)) AS payment_date
    OFFSET 0
) d
CROSS JOIN LATERAL (
    SELECT
        CASE WHEN TRIM(c.amount_paid::TEXT) ~ '^-?[0-9]+(\.[0-9]+)?$'
             THEN TRIM(c.amount_paid::TEXT)::NUMERIC END AS amount_paid,
        CASE WHEN TRIM(c.principal_component::TEXT) ~ '^-?[0-9]+(\.[0-9]+)?$'
             THEN TRIM(c.principal_component::TEXT)::NUMERIC END AS principal_component,
        CASE WHEN TRIM(c.interest_component::TEXT) ~ '^-?[0-9]+(\.[0-9]+)?$'
             THEN TRIM(c.interest_component::TEXT)::NUMERIC END AS interest_component
    OFFSET 0
) n;

COMMENT ON TABLE exploration.loan_payments_probe IS
    'Parsed snapshot of raw.loan_payments for data exploration. Rebuilt by explore_raw_loan_payments.sql, safe to drop.';

ANALYZE exploration.loan_payments_probe;


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
FROM raw.loan_payments c
CROSS JOIN LATERAL jsonb_each_text(to_jsonb(c)) AS j(key, value)
GROUP BY j.key
ORDER BY pct_missing DESC, column_name;


-- ============================================================
-- STEP 4: KEYS (payment_id and foreign keys)
-- ============================================================

-- 4.1 Key health
SELECT
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE payment_id_raw IS NULL
                        OR TRIM(payment_id_raw) = '')                   AS missing_key,
    COUNT(*) FILTER (WHERE TRIM(payment_id_raw) <> ''
                       AND TRIM(payment_id_raw) !~ '^[0-9]{1,18}$')     AS invalid_format,
    COUNT(DISTINCT TRIM(payment_id_raw))                                AS distinct_keys,
    COUNT(payment_id_raw) - COUNT(DISTINCT TRIM(payment_id_raw))               AS surplus_rows,
    MIN(LENGTH(TRIM(payment_id_raw)))                                   AS min_len,
    MAX(LENGTH(TRIM(payment_id_raw)))                                   AS max_len
FROM exploration.loan_payments_probe;

-- 4.2 Malformed keys (what do they look like?)
SELECT
    payment_id_raw,
    COUNT(*) AS row_count
FROM exploration.loan_payments_probe
WHERE payment_id_raw IS NOT NULL
  AND TRIM(payment_id_raw) !~ '^[0-9]{1,18}$'
GROUP BY payment_id_raw
ORDER BY row_count DESC
LIMIT 50;

-- 4.3 Duplicated keys: harmless reloads or real changes between loads?
WITH per_key AS (
    SELECT
        TRIM(payment_id::TEXT) AS k,
        COUNT(*)        AS copies,
        COUNT(DISTINCT ROW(loan_id, payment_date, amount_paid, principal_component, interest_component, late_payment_flag)::TEXT) AS versions
    FROM raw.loan_payments
    WHERE payment_id IS NOT NULL
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
    SELECT TRIM(payment_id::TEXT) AS k
    FROM raw.loan_payments
    WHERE payment_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT ROW(loan_id, payment_date, amount_paid, principal_component, interest_component, late_payment_flag)::TEXT) > 1
    LIMIT 5
)
SELECT c.*
FROM raw.loan_payments c
JOIN changed ch ON TRIM(c.payment_id::TEXT) = ch.k
ORDER BY ch.k, c._loaded_at;

-- 4.5 Foreign keys: missing, malformed, and ids with no parent row in raw
SELECT
    'loan_id'                                                       AS fk_column,
    'raw.loans.loan_id'                                              AS parent,
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE p.loan_id_raw IS NULL
                        OR TRIM(p.loan_id_raw) = '')                AS missing,
    COUNT(*) FILTER (WHERE TRIM(p.loan_id_raw) <> ''
                       AND TRIM(p.loan_id_raw) !~ '^[0-9]{1,18}$')  AS invalid_format,
    COUNT(*) FILTER (WHERE TRIM(p.loan_id_raw) ~ '^[0-9]{1,18}$'
                       AND r.id IS NULL)                         AS orphan_rows,
    COUNT(DISTINCT TRIM(p.loan_id_raw)) FILTER (WHERE TRIM(p.loan_id_raw) ~ '^[0-9]{1,18}$'
                                                AND r.id IS NULL) AS orphan_distinct_ids
FROM exploration.loan_payments_probe p
LEFT JOIN (
    SELECT DISTINCT TRIM(loan_id::TEXT) AS id
    FROM raw.loans
) r ON r.id = TRIM(p.loan_id_raw);


-- ============================================================
-- STEP 5: CATEGORICALS AND TEXT
-- Categoricals: values as stored, then the variants that merge after
-- trim + collapse spaces + Title Case (these are the dirty variants).
-- ============================================================

-- No categorical or free text columns in raw.loan_payments.


-- ============================================================
-- STEP 6: DATES
-- ============================================================

-- 6.1 Shape of the raw text (reveals mixed formats and time parts)
SELECT
    'payment_date'        AS column_name,
    translate(TRIM(payment_date_raw), '0123456789', '9999999999') AS shape,
    COUNT(*)     AS row_count,
    MIN(payment_date_raw) AS example_min,
    MAX(payment_date_raw) AS example_max
FROM exploration.loan_payments_probe
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 6.2 Validity and range
SELECT
    'payment_date'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE payment_date_raw IS NULL OR payment_date_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE payment_date_raw !~ '^\s*$' AND payment_date IS NULL)    AS unparsable,
    MIN(payment_date)                                                       AS min_date,
    MAX(payment_date)                                                       AS max_date,
    COUNT(*) FILTER (WHERE payment_date > CURRENT_DATE)                     AS in_future,
    DATE '2000-01-01'                                                    AS min_allowed,
    COUNT(*) FILTER (WHERE payment_date < DATE '2000-01-01')                      AS before_min_allowed
FROM exploration.loan_payments_probe;

-- 6.3 Rows per year
SELECT
    'payment_date'                      AS column_name,
    EXTRACT(YEAR FROM payment_date)::INT AS yr,
    COUNT(*)                   AS row_count
FROM exploration.loan_payments_probe
WHERE payment_date IS NOT NULL
GROUP BY 2
ORDER BY column_name, yr;


-- ============================================================
-- STEP 7: NUMERICS AND FLAGS
-- non_numeric = text that is not a plain number (commas, currency signs, 'k', words).
-- ============================================================

-- 7.1 amount_paid: profile
SELECT
    'amount_paid'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE amount_paid_raw IS NULL OR amount_paid_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE amount_paid_raw !~ '^\s*$' AND amount_paid IS NULL)    AS non_numeric,
    COUNT(*) FILTER (WHERE amount_paid < 0)                                AS negative,
    COUNT(*) FILTER (WHERE amount_paid = 0)                                AS zero,
    MIN(amount_paid)                                                       AS min_value,
    MAX(amount_paid)                                                       AS max_value,
    ROUND(AVG(amount_paid), 2)                                             AS avg_value,
    ROUND(STDDEV(amount_paid), 2)                                          AS stddev_value,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY amount_paid)              AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY amount_paid)              AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY amount_paid)              AS p75,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY amount_paid)              AS p99,
    MAX(LENGTH(SPLIT_PART(TRIM(amount_paid_raw), '.', 2)))                 AS max_decimals
FROM exploration.loan_payments_probe;

-- 7.2 amount_paid: the text values that are not numbers
SELECT
    amount_paid_raw,
    COUNT(*) AS row_count
FROM exploration.loan_payments_probe
WHERE amount_paid_raw !~ '^\s*$'
  AND amount_paid IS NULL
GROUP BY amount_paid_raw
ORDER BY row_count DESC
LIMIT 50;

-- 7.3 amount_paid: outlier fences (IQR rule on positive values)
WITH q AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY amount_paid) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY amount_paid) AS q3
    FROM exploration.loan_payments_probe
    WHERE amount_paid > 0
)
SELECT
    q.q1,
    q.q3,
    q.q3 - q.q1                                   AS iqr,
    q.q1 - 1.5 * (q.q3 - q.q1)                    AS lower_fence,
    q.q3 + 1.5 * (q.q3 - q.q1)                    AS upper_fence,
    (SELECT COUNT(*) FROM exploration.loan_payments_probe p
     WHERE p.amount_paid > q.q3 + 1.5 * (q.q3 - q.q1))    AS rows_above_fence
FROM q;

-- 7.4 amount_paid: order of magnitude (spots unit mix ups)
SELECT
    FLOOR(LOG(amount_paid))::INT AS power_of_10,
    COUNT(*)             AS row_count,
    MIN(amount_paid)             AS min_value,
    MAX(amount_paid)             AS max_value
FROM exploration.loan_payments_probe
WHERE amount_paid > 0
GROUP BY 1
ORDER BY 1;

-- 7.5 amount_paid: extremes
(SELECT 'highest' AS side, payment_id_raw, amount_paid FROM exploration.loan_payments_probe
 WHERE amount_paid IS NOT NULL ORDER BY amount_paid DESC LIMIT 20)
UNION ALL
(SELECT 'lowest', payment_id_raw, amount_paid FROM exploration.loan_payments_probe
 WHERE amount_paid IS NOT NULL ORDER BY amount_paid ASC LIMIT 20);

-- 7.6 principal_component: profile
SELECT
    'principal_component'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE principal_component_raw IS NULL OR principal_component_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE principal_component_raw !~ '^\s*$' AND principal_component IS NULL)    AS non_numeric,
    COUNT(*) FILTER (WHERE principal_component < 0)                                AS negative,
    COUNT(*) FILTER (WHERE principal_component = 0)                                AS zero,
    MIN(principal_component)                                                       AS min_value,
    MAX(principal_component)                                                       AS max_value,
    ROUND(AVG(principal_component), 2)                                             AS avg_value,
    ROUND(STDDEV(principal_component), 2)                                          AS stddev_value,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY principal_component)              AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY principal_component)              AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY principal_component)              AS p75,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY principal_component)              AS p99,
    MAX(LENGTH(SPLIT_PART(TRIM(principal_component_raw), '.', 2)))                 AS max_decimals
FROM exploration.loan_payments_probe;

-- 7.7 principal_component: the text values that are not numbers
SELECT
    principal_component_raw,
    COUNT(*) AS row_count
FROM exploration.loan_payments_probe
WHERE principal_component_raw !~ '^\s*$'
  AND principal_component IS NULL
GROUP BY principal_component_raw
ORDER BY row_count DESC
LIMIT 50;

-- 7.8 principal_component: outlier fences (IQR rule on positive values)
WITH q AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY principal_component) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY principal_component) AS q3
    FROM exploration.loan_payments_probe
    WHERE principal_component > 0
)
SELECT
    q.q1,
    q.q3,
    q.q3 - q.q1                                   AS iqr,
    q.q1 - 1.5 * (q.q3 - q.q1)                    AS lower_fence,
    q.q3 + 1.5 * (q.q3 - q.q1)                    AS upper_fence,
    (SELECT COUNT(*) FROM exploration.loan_payments_probe p
     WHERE p.principal_component > q.q3 + 1.5 * (q.q3 - q.q1))    AS rows_above_fence
FROM q;

-- 7.9 principal_component: order of magnitude (spots unit mix ups)
SELECT
    FLOOR(LOG(principal_component))::INT AS power_of_10,
    COUNT(*)             AS row_count,
    MIN(principal_component)             AS min_value,
    MAX(principal_component)             AS max_value
FROM exploration.loan_payments_probe
WHERE principal_component > 0
GROUP BY 1
ORDER BY 1;

-- 7.10 principal_component: extremes
(SELECT 'highest' AS side, payment_id_raw, principal_component FROM exploration.loan_payments_probe
 WHERE principal_component IS NOT NULL ORDER BY principal_component DESC LIMIT 20)
UNION ALL
(SELECT 'lowest', payment_id_raw, principal_component FROM exploration.loan_payments_probe
 WHERE principal_component IS NOT NULL ORDER BY principal_component ASC LIMIT 20);

-- 7.11 interest_component: profile
SELECT
    'interest_component'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE interest_component_raw IS NULL OR interest_component_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE interest_component_raw !~ '^\s*$' AND interest_component IS NULL)    AS non_numeric,
    COUNT(*) FILTER (WHERE interest_component < 0)                                AS negative,
    COUNT(*) FILTER (WHERE interest_component = 0)                                AS zero,
    MIN(interest_component)                                                       AS min_value,
    MAX(interest_component)                                                       AS max_value,
    ROUND(AVG(interest_component), 2)                                             AS avg_value,
    ROUND(STDDEV(interest_component), 2)                                          AS stddev_value,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY interest_component)              AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY interest_component)              AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY interest_component)              AS p75,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY interest_component)              AS p99,
    MAX(LENGTH(SPLIT_PART(TRIM(interest_component_raw), '.', 2)))                 AS max_decimals
FROM exploration.loan_payments_probe;

-- 7.12 interest_component: the text values that are not numbers
SELECT
    interest_component_raw,
    COUNT(*) AS row_count
FROM exploration.loan_payments_probe
WHERE interest_component_raw !~ '^\s*$'
  AND interest_component IS NULL
GROUP BY interest_component_raw
ORDER BY row_count DESC
LIMIT 50;

-- 7.13 interest_component: outlier fences (IQR rule on positive values)
WITH q AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY interest_component) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY interest_component) AS q3
    FROM exploration.loan_payments_probe
    WHERE interest_component > 0
)
SELECT
    q.q1,
    q.q3,
    q.q3 - q.q1                                   AS iqr,
    q.q1 - 1.5 * (q.q3 - q.q1)                    AS lower_fence,
    q.q3 + 1.5 * (q.q3 - q.q1)                    AS upper_fence,
    (SELECT COUNT(*) FROM exploration.loan_payments_probe p
     WHERE p.interest_component > q.q3 + 1.5 * (q.q3 - q.q1))    AS rows_above_fence
FROM q;

-- 7.14 interest_component: order of magnitude (spots unit mix ups)
SELECT
    FLOOR(LOG(interest_component))::INT AS power_of_10,
    COUNT(*)             AS row_count,
    MIN(interest_component)             AS min_value,
    MAX(interest_component)             AS max_value
FROM exploration.loan_payments_probe
WHERE interest_component > 0
GROUP BY 1
ORDER BY 1;

-- 7.15 interest_component: extremes
(SELECT 'highest' AS side, payment_id_raw, interest_component FROM exploration.loan_payments_probe
 WHERE interest_component IS NOT NULL ORDER BY interest_component DESC LIMIT 20)
UNION ALL
(SELECT 'lowest', payment_id_raw, interest_component FROM exploration.loan_payments_probe
 WHERE interest_component IS NOT NULL ORDER BY interest_component ASC LIMIT 20);

-- 7.16 late_payment_flag: flag values as stored and whether they parse
SELECT
    COALESCE(late_payment_flag_raw, '<NULL>')  AS raw_value,
    late_payment_flag                          AS parsed_value,
    COUNT(*)                     AS row_count
FROM exploration.loan_payments_probe
GROUP BY late_payment_flag_raw, late_payment_flag
ORDER BY row_count DESC;


-- ============================================================
-- STEP 8: CROSS CHECKS (rules that span columns)
-- ============================================================

-- 8.1 Amount maths: amount_paid = principal_component + interest_component (tolerance 0.01)
SELECT
    COUNT(*)                                                           AS total_rows,
    COUNT(*) FILTER (WHERE amount_paid IS NOT NULL
                       AND principal_component IS NOT NULL
                       AND interest_component IS NOT NULL)             AS all_three_present,
    COUNT(*) FILTER (WHERE amount_paid IS NOT NULL
                       AND principal_component IS NOT NULL
                       AND interest_component IS NOT NULL
                       AND ABS(amount_paid - (principal_component + interest_component)) <= 0.01)
                                                                       AS adds_up,
    COUNT(*) FILTER (WHERE amount_paid IS NOT NULL
                       AND principal_component IS NOT NULL
                       AND interest_component IS NOT NULL
                       AND ABS(amount_paid - (principal_component + interest_component)) > 0.01)
                                                                       AS mismatch,
    COUNT(*) FILTER (WHERE (amount_paid IS NULL)::INT
                         + (principal_component IS NULL)::INT
                         + (interest_component IS NULL)::INT = 1)      AS one_missing_rebuildable,
    COUNT(*) FILTER (WHERE (amount_paid IS NULL)::INT
                         + (principal_component IS NULL)::INT
                         + (interest_component IS NULL)::INT >= 2)     AS two_or_more_missing
FROM exploration.loan_payments_probe;

-- 8.2 Mismatch size: how far off are the rows that do not add up?
SELECT
    MIN(amount_paid - (principal_component + interest_component))           AS min_diff,
    ROUND(AVG(amount_paid - (principal_component + interest_component)), 2) AS avg_diff,
    MAX(amount_paid - (principal_component + interest_component))           AS max_diff
FROM exploration.loan_payments_probe
WHERE amount_paid IS NOT NULL
  AND principal_component IS NOT NULL
  AND interest_component IS NOT NULL
  AND ABS(amount_paid - (principal_component + interest_component)) > 0.01;

-- 8.3 Late payment share
SELECT
    late_payment_flag,
    COUNT(*)                                                 AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)       AS pct
FROM exploration.loan_payments_probe
GROUP BY late_payment_flag
ORDER BY late_payment_flag;

-- 8.4 Payments dated before the loan start_date (latest loan row used)
SELECT
    COUNT(*)                                          AS matched_payments,
    COUNT(*) FILTER (WHERE p.payment_date < l.start_date) AS paid_before_loan_start
FROM exploration.loan_payments_probe p
JOIN (
    SELECT DISTINCT ON (TRIM(loan_id::TEXT))
        TRIM(loan_id::TEXT)                                    AS lid,
        staging.try_date(LEFT(TRIM(start_date::TEXT), 10))     AS start_date
    FROM raw.loans
    ORDER BY TRIM(loan_id::TEXT), _loaded_at DESC NULLS LAST
) l ON l.lid = TRIM(p.loan_id_raw);


-- ============================================================
-- STEP 9: METADATA COLUMNS
-- ============================================================

-- 9.1 One row per load batch
SELECT
    _batch_id,
    COUNT(*)                 AS row_count,
    COUNT(DISTINCT payment_id)      AS distinct_keys,
    MIN(_loaded_at)          AS first_loaded,
    MAX(_loaded_at)          AS last_loaded
FROM raw.loan_payments
GROUP BY _batch_id
ORDER BY first_loaded;

-- 9.2 Shape of the timestamp columns (mixed formats show up as extra rows)
SELECT
    'created_at' AS column_name,
    translate(created_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(created_at::TEXT) AS min_value,
    MAX(created_at::TEXT) AS max_value
FROM raw.loan_payments
GROUP BY 2
UNION ALL
SELECT
    'loaded_at' AS column_name,
    translate(loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(loaded_at::TEXT) AS min_value,
    MAX(loaded_at::TEXT) AS max_value
FROM raw.loan_payments
GROUP BY 2
UNION ALL
SELECT
    '_loaded_at' AS column_name,
    translate(_loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(_loaded_at::TEXT) AS min_value,
    MAX(_loaded_at::TEXT) AS max_value
FROM raw.loan_payments
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 9.3 Keys that appear in more than one batch (drives the dedupe rule)
SELECT COUNT(*) AS keys_in_multiple_batches
FROM (
    SELECT TRIM(payment_id::TEXT)
    FROM raw.loan_payments
    WHERE payment_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT _batch_id) > 1
) x;


-- ============================================================
-- STEP 10: RULE IMPACT
-- Rows each candidate cleaning rule would reject or NULL out.
-- Use this list to decide the rules in the staging procedure.
-- ============================================================

WITH t AS (
    SELECT COUNT(*) AS total FROM exploration.loan_payments_probe
)
SELECT
    r.rule,
    r.failing_rows,
    ROUND(100.0 * r.failing_rows / NULLIF(t.total, 0), 2) AS pct_of_rows
FROM t
CROSS JOIN LATERAL (VALUES
    ('payment_id missing or not 1-18 digits (row would be dropped)',
        (SELECT COUNT(*) FROM exploration.loan_payments_probe WHERE payment_id_raw IS NULL OR TRIM(payment_id_raw) !~ '^[0-9]{1,18}$')),
    ('surplus duplicate rows per payment_id (dedupe removes these)',
        (SELECT COUNT(payment_id_raw) - COUNT(DISTINCT TRIM(payment_id_raw)) FROM exploration.loan_payments_probe)),
    ('loan_id present but not 1-18 digits',
        (SELECT COUNT(*) FROM exploration.loan_payments_probe WHERE TRIM(loan_id_raw) <> '' AND TRIM(loan_id_raw) !~ '^[0-9]{1,18}$')),
    ('loan_id has no parent row in raw.loans',
        (SELECT COUNT(*) FROM exploration.loan_payments_probe p WHERE TRIM(p.loan_id_raw) ~ '^[0-9]{1,18}$' AND NOT EXISTS (SELECT 1 FROM raw.loans r WHERE TRIM(r.loan_id::TEXT) = TRIM(p.loan_id_raw)))),
    ('payment_date present but not a valid date',
        (SELECT COUNT(*) FROM exploration.loan_payments_probe WHERE payment_date_raw !~ '^\s*$' AND payment_date IS NULL)),
    ('payment_date before 2000-01-01',
        (SELECT COUNT(*) FROM exploration.loan_payments_probe WHERE payment_date < DATE '2000-01-01')),
    ('payment_date in the future',
        (SELECT COUNT(*) FROM exploration.loan_payments_probe WHERE payment_date > CURRENT_DATE)),
    ('amount_paid present but not numeric',
        (SELECT COUNT(*) FROM exploration.loan_payments_probe WHERE amount_paid_raw !~ '^\s*$' AND amount_paid IS NULL)),
    ('amount_paid zero or negative',
        (SELECT COUNT(*) FROM exploration.loan_payments_probe WHERE amount_paid <= 0)),
    ('principal_component present but not numeric',
        (SELECT COUNT(*) FROM exploration.loan_payments_probe WHERE principal_component_raw !~ '^\s*$' AND principal_component IS NULL)),
    ('interest_component present but not numeric',
        (SELECT COUNT(*) FROM exploration.loan_payments_probe WHERE interest_component_raw !~ '^\s*$' AND interest_component IS NULL)),
    ('late_payment_flag present but not a recognised flag',
        (SELECT COUNT(*) FROM exploration.loan_payments_probe WHERE late_payment_flag_raw !~ '^\s*$' AND late_payment_flag IS NULL)),
    ('amount_paid differs from principal + interest by more than 0.01',
        (SELECT COUNT(*) FROM exploration.loan_payments_probe WHERE amount_paid IS NOT NULL AND principal_component IS NOT NULL
         AND interest_component IS NOT NULL
         AND ABS(amount_paid - (principal_component + interest_component)) > 0.01))
) AS r(rule, failing_rows)
ORDER BY r.failing_rows DESC;
