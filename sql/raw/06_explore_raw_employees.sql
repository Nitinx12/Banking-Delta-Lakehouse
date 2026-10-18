-- ============================================================
-- Script:   explore_raw_employees.sql
-- Purpose:  Profile raw.employees BEFORE writing its staging procedure
-- Database: banking_delta (schema: raw)
-- Writes:   Only exploration.employees_probe (dropped and rebuilt on every run).
--           raw.employees is never modified.
-- Run: psql -U postgres -d banking_delta -f .\sql\exploration\explore_raw_employees.sql
--      or run it one step at a time in your SQL client and read each result.
--
-- Needs: staging.try_date(TEXT) from 06_sp_load_card_transactions_scd1.sql
-- Key:   employee_id
-- Note:  hire_date is checked from 1980-01-01.
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
--   hire_date from 1980-01-01 to today
--   salary greater than 0
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
FROM raw.employees;

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
  AND table_name   = 'employees'
ORDER BY ordinal_position;

-- 1.2 First rows as stored
SELECT *
FROM raw.employees
LIMIT 50;

-- 1.3 Random rows (first rows are rarely representative)
SELECT *
FROM raw.employees
ORDER BY random()
LIMIT 50;


-- ============================================================
-- STEP 2: WORKING SET
-- Parse dates, numbers and flags once; every later step reads this table.
-- Columns: <col>_raw is the stored text, <col> is the parsed value.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS exploration;

DROP TABLE IF EXISTS exploration.employees_probe;

CREATE TABLE exploration.employees_probe AS
SELECT
    c.employee_id::TEXT AS employee_id_raw,
    c.branch_id::TEXT AS branch_id_raw,
    c.role::TEXT AS role_raw,
    c.name::TEXT AS name_raw,
    c.hire_date::TEXT AS hire_date_raw,
    c.salary::TEXT AS salary_raw,
    d.hire_date,
    n.salary,
    CURRENT_TIMESTAMP AS probed_at
FROM raw.employees c
CROSS JOIN LATERAL (
    SELECT
        staging.try_date(LEFT(TRIM(c.hire_date::TEXT), 10)) AS hire_date
    OFFSET 0
) d
CROSS JOIN LATERAL (
    SELECT
        CASE WHEN TRIM(c.salary::TEXT) ~ '^-?[0-9]+(\.[0-9]+)?$'
             THEN TRIM(c.salary::TEXT)::NUMERIC END AS salary
    OFFSET 0
) n;

COMMENT ON TABLE exploration.employees_probe IS
    'Parsed snapshot of raw.employees for data exploration. Rebuilt by explore_raw_employees.sql, safe to drop.';

ANALYZE exploration.employees_probe;


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
FROM raw.employees c
CROSS JOIN LATERAL jsonb_each_text(to_jsonb(c)) AS j(key, value)
GROUP BY j.key
ORDER BY pct_missing DESC, column_name;


-- ============================================================
-- STEP 4: KEYS (employee_id and foreign keys)
-- ============================================================

-- 4.1 Key health
SELECT
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE employee_id_raw IS NULL
                        OR TRIM(employee_id_raw) = '')                   AS missing_key,
    COUNT(*) FILTER (WHERE TRIM(employee_id_raw) <> ''
                       AND TRIM(employee_id_raw) !~ '^[0-9]{1,18}$')     AS invalid_format,
    COUNT(DISTINCT TRIM(employee_id_raw))                                AS distinct_keys,
    COUNT(employee_id_raw) - COUNT(DISTINCT TRIM(employee_id_raw))               AS surplus_rows,
    MIN(LENGTH(TRIM(employee_id_raw)))                                   AS min_len,
    MAX(LENGTH(TRIM(employee_id_raw)))                                   AS max_len
FROM exploration.employees_probe;

-- 4.2 Malformed keys (what do they look like?)
SELECT
    employee_id_raw,
    COUNT(*) AS row_count
FROM exploration.employees_probe
WHERE employee_id_raw IS NOT NULL
  AND TRIM(employee_id_raw) !~ '^[0-9]{1,18}$'
GROUP BY employee_id_raw
ORDER BY row_count DESC
LIMIT 50;

-- 4.3 Duplicated keys: harmless reloads or real changes between loads?
WITH per_key AS (
    SELECT
        TRIM(employee_id::TEXT) AS k,
        COUNT(*)        AS copies,
        COUNT(DISTINCT ROW(branch_id, role, name, hire_date, salary)::TEXT) AS versions
    FROM raw.employees
    WHERE employee_id IS NOT NULL
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
    SELECT TRIM(employee_id::TEXT) AS k
    FROM raw.employees
    WHERE employee_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT ROW(branch_id, role, name, hire_date, salary)::TEXT) > 1
    LIMIT 5
)
SELECT c.*
FROM raw.employees c
JOIN changed ch ON TRIM(c.employee_id::TEXT) = ch.k
ORDER BY ch.k, c._loaded_at;

-- 4.5 Foreign keys: missing, malformed, and ids with no parent row in raw
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
FROM exploration.employees_probe p
LEFT JOIN (
    SELECT DISTINCT TRIM(branch_id::TEXT) AS id
    FROM raw.branches
) r ON r.id = TRIM(p.branch_id_raw);


-- ============================================================
-- STEP 5: CATEGORICALS AND TEXT
-- Categoricals: values as stored, then the variants that merge after
-- trim + collapse spaces + Title Case (these are the dirty variants).
-- ============================================================

-- 5.1 role: values as stored
SELECT
    COALESCE(role_raw, '<NULL>') AS raw_value,
    COUNT(*)                    AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.employees_probe
GROUP BY role_raw
ORDER BY row_count DESC
LIMIT 100;

-- 5.2 role: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(role_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT role_raw)                                 AS raw_variants,
    array_agg(DISTINCT role_raw)                             AS raw_values,
    COUNT(*)                                                AS row_count
FROM exploration.employees_probe
WHERE role_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT role_raw) > 1
ORDER BY row_count DESC
LIMIT 100;

-- 5.3 name: profile
SELECT
    'name'                                                         AS column_name,
    COUNT(*)                                                      AS total_rows,
    COUNT(*) FILTER (WHERE name_raw IS NULL OR name_raw ~ '^\s*$')  AS missing,
    COUNT(*) FILTER (WHERE name_raw ~ '^\s|\s$')                   AS padded,
    COUNT(*) FILTER (WHERE name_raw ~ '\s{2,}')                    AS double_spaces,
    MIN(LENGTH(TRIM(name_raw)))                                    AS min_len,
    MAX(LENGTH(TRIM(name_raw)))                                    AS max_len,
    COUNT(DISTINCT name_raw)                                       AS distinct_raw,
    COUNT(DISTINCT LOWER(regexp_replace(TRIM(name_raw), '\s+', ' ', 'g'))) AS distinct_cleaned,
    COUNT(*) FILTER (WHERE name_raw ~ '[0-9]')                          AS has_digits,
    COUNT(*) FILTER (WHERE name_raw ~ '[^A-Za-z .''-]')                 AS odd_characters,
    COUNT(*) FILTER (WHERE name_raw ~ '[A-Z]' AND name_raw !~ '[a-z]') AS all_upper,
    COUNT(*) FILTER (WHERE name_raw ~ '[a-z]' AND name_raw !~ '[A-Z]') AS all_lower
FROM exploration.employees_probe;


-- ============================================================
-- STEP 6: DATES
-- ============================================================

-- 6.1 Shape of the raw text (reveals mixed formats and time parts)
SELECT
    'hire_date'        AS column_name,
    translate(TRIM(hire_date_raw), '0123456789', '9999999999') AS shape,
    COUNT(*)     AS row_count,
    MIN(hire_date_raw) AS example_min,
    MAX(hire_date_raw) AS example_max
FROM exploration.employees_probe
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 6.2 Validity and range
SELECT
    'hire_date'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE hire_date_raw IS NULL OR hire_date_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE hire_date_raw !~ '^\s*$' AND hire_date IS NULL)    AS unparsable,
    MIN(hire_date)                                                       AS min_date,
    MAX(hire_date)                                                       AS max_date,
    COUNT(*) FILTER (WHERE hire_date > CURRENT_DATE)                     AS in_future,
    DATE '1980-01-01'                                                    AS min_allowed,
    COUNT(*) FILTER (WHERE hire_date < DATE '1980-01-01')                      AS before_min_allowed
FROM exploration.employees_probe;

-- 6.3 Rows per year
SELECT
    'hire_date'                      AS column_name,
    EXTRACT(YEAR FROM hire_date)::INT AS yr,
    COUNT(*)                   AS row_count
FROM exploration.employees_probe
WHERE hire_date IS NOT NULL
GROUP BY 2
ORDER BY column_name, yr;


-- ============================================================
-- STEP 7: NUMERICS AND FLAGS
-- non_numeric = text that is not a plain number (commas, currency signs, 'k', words).
-- ============================================================

-- 7.1 salary: profile
SELECT
    'salary'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE salary_raw IS NULL OR salary_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE salary_raw !~ '^\s*$' AND salary IS NULL)    AS non_numeric,
    COUNT(*) FILTER (WHERE salary < 0)                                AS negative,
    COUNT(*) FILTER (WHERE salary = 0)                                AS zero,
    MIN(salary)                                                       AS min_value,
    MAX(salary)                                                       AS max_value,
    ROUND(AVG(salary), 2)                                             AS avg_value,
    ROUND(STDDEV(salary), 2)                                          AS stddev_value,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY salary)              AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY salary)              AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY salary)              AS p75,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY salary)              AS p99,
    MAX(LENGTH(SPLIT_PART(TRIM(salary_raw), '.', 2)))                 AS max_decimals
FROM exploration.employees_probe;

-- 7.2 salary: the text values that are not numbers
SELECT
    salary_raw,
    COUNT(*) AS row_count
FROM exploration.employees_probe
WHERE salary_raw !~ '^\s*$'
  AND salary IS NULL
GROUP BY salary_raw
ORDER BY row_count DESC
LIMIT 50;

-- 7.3 salary: outlier fences (IQR rule on positive values)
WITH q AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY salary) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY salary) AS q3
    FROM exploration.employees_probe
    WHERE salary > 0
)
SELECT
    q.q1,
    q.q3,
    q.q3 - q.q1                                   AS iqr,
    q.q1 - 1.5 * (q.q3 - q.q1)                    AS lower_fence,
    q.q3 + 1.5 * (q.q3 - q.q1)                    AS upper_fence,
    (SELECT COUNT(*) FROM exploration.employees_probe p
     WHERE p.salary > q.q3 + 1.5 * (q.q3 - q.q1))    AS rows_above_fence
FROM q;

-- 7.4 salary: order of magnitude (spots unit mix ups)
SELECT
    FLOOR(LOG(salary))::INT AS power_of_10,
    COUNT(*)             AS row_count,
    MIN(salary)             AS min_value,
    MAX(salary)             AS max_value
FROM exploration.employees_probe
WHERE salary > 0
GROUP BY 1
ORDER BY 1;

-- 7.5 salary: extremes
(SELECT 'highest' AS side, employee_id_raw, salary FROM exploration.employees_probe
 WHERE salary IS NOT NULL ORDER BY salary DESC LIMIT 20)
UNION ALL
(SELECT 'lowest', employee_id_raw, salary FROM exploration.employees_probe
 WHERE salary IS NOT NULL ORDER BY salary ASC LIMIT 20);


-- ============================================================
-- STEP 8: CROSS CHECKS (rules that span columns)
-- ============================================================

-- 8.1 salary by role (do the groups make sense?)
SELECT
    INITCAP(regexp_replace(TRIM(role_raw), '\s+', ' ', 'g')) AS role,
    COUNT(*)                                                  AS row_count,
    COUNT(salary)                                               AS numeric_rows,
    MIN(salary)                                                 AS min_value,
    ROUND(AVG(salary), 2)                                       AS avg_value,
    MAX(salary)                                                 AS max_value
FROM exploration.employees_probe
WHERE role_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC;


-- ============================================================
-- STEP 9: METADATA COLUMNS
-- ============================================================

-- 9.1 One row per load batch
SELECT
    _batch_id,
    COUNT(*)                 AS row_count,
    COUNT(DISTINCT employee_id)      AS distinct_keys,
    MIN(_loaded_at)          AS first_loaded,
    MAX(_loaded_at)          AS last_loaded
FROM raw.employees
GROUP BY _batch_id
ORDER BY first_loaded;

-- 9.2 Shape of the timestamp columns (mixed formats show up as extra rows)
SELECT
    'created_at' AS column_name,
    translate(created_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(created_at::TEXT) AS min_value,
    MAX(created_at::TEXT) AS max_value
FROM raw.employees
GROUP BY 2
UNION ALL
SELECT
    'loaded_at' AS column_name,
    translate(loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(loaded_at::TEXT) AS min_value,
    MAX(loaded_at::TEXT) AS max_value
FROM raw.employees
GROUP BY 2
UNION ALL
SELECT
    '_loaded_at' AS column_name,
    translate(_loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(_loaded_at::TEXT) AS min_value,
    MAX(_loaded_at::TEXT) AS max_value
FROM raw.employees
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 9.3 Keys that appear in more than one batch (drives the dedupe rule)
SELECT COUNT(*) AS keys_in_multiple_batches
FROM (
    SELECT TRIM(employee_id::TEXT)
    FROM raw.employees
    WHERE employee_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT _batch_id) > 1
) x;


-- ============================================================
-- STEP 10: RULE IMPACT
-- Rows each candidate cleaning rule would reject or NULL out.
-- Use this list to decide the rules in the staging procedure.
-- ============================================================

WITH t AS (
    SELECT COUNT(*) AS total FROM exploration.employees_probe
)
SELECT
    r.rule,
    r.failing_rows,
    ROUND(100.0 * r.failing_rows / NULLIF(t.total, 0), 2) AS pct_of_rows
FROM t
CROSS JOIN LATERAL (VALUES
    ('employee_id missing or not 1-18 digits (row would be dropped)',
        (SELECT COUNT(*) FROM exploration.employees_probe WHERE employee_id_raw IS NULL OR TRIM(employee_id_raw) !~ '^[0-9]{1,18}$')),
    ('surplus duplicate rows per employee_id (dedupe removes these)',
        (SELECT COUNT(employee_id_raw) - COUNT(DISTINCT TRIM(employee_id_raw)) FROM exploration.employees_probe)),
    ('branch_id present but not 1-18 digits',
        (SELECT COUNT(*) FROM exploration.employees_probe WHERE TRIM(branch_id_raw) <> '' AND TRIM(branch_id_raw) !~ '^[0-9]{1,18}$')),
    ('branch_id has no parent row in raw.branches',
        (SELECT COUNT(*) FROM exploration.employees_probe p WHERE TRIM(p.branch_id_raw) ~ '^[0-9]{1,18}$' AND NOT EXISTS (SELECT 1 FROM raw.branches r WHERE TRIM(r.branch_id::TEXT) = TRIM(p.branch_id_raw)))),
    ('hire_date present but not a valid date',
        (SELECT COUNT(*) FROM exploration.employees_probe WHERE hire_date_raw !~ '^\s*$' AND hire_date IS NULL)),
    ('hire_date before 1980-01-01',
        (SELECT COUNT(*) FROM exploration.employees_probe WHERE hire_date < DATE '1980-01-01')),
    ('hire_date in the future',
        (SELECT COUNT(*) FROM exploration.employees_probe WHERE hire_date > CURRENT_DATE)),
    ('salary present but not numeric',
        (SELECT COUNT(*) FROM exploration.employees_probe WHERE salary_raw !~ '^\s*$' AND salary IS NULL)),
    ('salary zero or negative',
        (SELECT COUNT(*) FROM exploration.employees_probe WHERE salary <= 0))
) AS r(rule, failing_rows)
ORDER BY r.failing_rows DESC;
