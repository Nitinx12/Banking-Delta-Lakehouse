-- ============================================================
-- Script:   01_explore_raw_customers.sql
-- Purpose:  Profile raw.customers BEFORE writing its staging procedure
-- Database: banking_delta (schema: raw)
-- Writes:   Only exploration.customers_probe (dropped and rebuilt on every run).
--           raw.customers is never modified.
-- Run: psql -U postgres -d banking_delta -f .\sql\exploration\explore_raw_customers.sql
--      or run it one step at a time in your SQL client and read each result.
--
-- Needs: staging.try_date(TEXT) from 06_sp_load_card_transactions_scd1.sql
-- Assumes: customer_id is the business key (not seen in your queries yet).
--
-- Steps (always in this order, each step feeds the next):
--   0  Context        what are we looking at, is it safe to proceed
--   1  Structure      columns, types, sample rows
--   2  Working set    parse dates and numbers ONCE into exploration.customers_probe
--   3  Column profile nulls, blanks, padding, placeholders, cardinality
--   4  Key            customer_id: missing, malformed, duplicated, reloaded
--   5  Categoricals   gender, city, state, occupation: values and variants
--   6  Dates          date_of_birth, join_date: shape, validity, range
--   7  Numerics       annual_income, credit_score: shape, range, outliers
--   8  Email          format, case, padding, duplicates, domains
--   9  Cross checks   rules that span more than one column
--   10 Metadata       batches and load timestamps
--   11 Rule impact    rows each candidate cleaning rule would reject
--
-- Thresholds used below are ASSUMPTIONS, confirm them with the data:
--   age 18 to 100, join_date from 2000-01-01 to today,
--   credit_score 300 to 900, annual_income greater than 0.
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
FROM raw.customers;

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
  AND table_name   = 'customers'
ORDER BY ordinal_position;

-- 1.2 First rows as stored
SELECT *
FROM raw.customers
LIMIT 50;

-- 1.3 Random rows (first rows are rarely representative)
SELECT *
FROM raw.customers
ORDER BY random()
LIMIT 50;


-- ============================================================
-- STEP 2: WORKING SET
-- Parse dates and numbers once; every later step reads this table.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS exploration;

DROP TABLE IF EXISTS exploration.customers_probe;

CREATE TABLE exploration.customers_probe AS
SELECT
    c.customer_id::TEXT   AS customer_id_raw,
    c.gender::TEXT        AS gender_raw,
    c.city::TEXT          AS city_raw,
    c.state::TEXT         AS state_raw,
    c.occupation::TEXT    AS occupation_raw,
    c.email::TEXT         AS email_raw,
    c.date_of_birth::TEXT AS dob_raw,
    c.join_date::TEXT     AS join_raw,
    c.annual_income::TEXT AS income_raw,
    c.credit_score::TEXT  AS score_raw,
    d.dob,
    d.jd,
    n.income,
    n.score,
    CURRENT_TIMESTAMP     AS probed_at
FROM raw.customers c
CROSS JOIN LATERAL (
    SELECT
        staging.try_date(LEFT(TRIM(c.date_of_birth::TEXT), 10)) AS dob,
        staging.try_date(LEFT(TRIM(c.join_date::TEXT), 10))     AS jd
    OFFSET 0
) d
CROSS JOIN LATERAL (
    SELECT
        CASE WHEN TRIM(c.annual_income::TEXT) ~ '^-?[0-9]+(\.[0-9]+)?$'
             THEN TRIM(c.annual_income::TEXT)::NUMERIC END AS income,
        CASE WHEN TRIM(c.credit_score::TEXT) ~ '^-?[0-9]+(\.[0-9]+)?$'
             THEN TRIM(c.credit_score::TEXT)::NUMERIC END  AS score
    OFFSET 0
) n;

COMMENT ON TABLE exploration.customers_probe IS
    'Parsed snapshot of raw.customers for data exploration. Rebuilt by explore_raw_customers.sql, safe to drop.';

ANALYZE exploration.customers_probe;


-- ============================================================
-- STEP 3: COLUMN PROFILE (works for every column, including ones not named here)
-- null = SQL NULL, blank = empty or spaces, padded = leading/trailing space,
-- placeholder = text such as 'null', 'N/A', 'nan'.
-- ============================================================

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
FROM raw.customers c
CROSS JOIN LATERAL jsonb_each_text(to_jsonb(c)) AS j(key, value)
GROUP BY j.key
ORDER BY pct_missing DESC, column_name;


-- ============================================================
-- STEP 4: KEY (customer_id)
-- ============================================================

-- 4.1 Key health
SELECT
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE customer_id_raw IS NULL
                        OR TRIM(customer_id_raw) = '')           AS missing_id,
    COUNT(*) FILTER (WHERE TRIM(customer_id_raw) <> ''
                       AND TRIM(customer_id_raw) !~ '^[0-9]{1,18}$')
                                                                 AS invalid_format,
    COUNT(DISTINCT TRIM(customer_id_raw))                        AS distinct_ids,
    COUNT(*) - COUNT(DISTINCT TRIM(customer_id_raw))             AS surplus_rows,
    MIN(LENGTH(TRIM(customer_id_raw)))                           AS min_len,
    MAX(LENGTH(TRIM(customer_id_raw)))                           AS max_len
FROM exploration.customers_probe;

-- 4.2 Malformed ids (what do they look like?)
SELECT
    customer_id_raw,
    COUNT(*) AS row_count
FROM exploration.customers_probe
WHERE customer_id_raw IS NOT NULL
  AND TRIM(customer_id_raw) !~ '^[0-9]{1,18}$'
GROUP BY customer_id_raw
ORDER BY row_count DESC
LIMIT 50;

-- 4.3 Duplicated ids: harmless reloads or real changes between loads?
WITH per_id AS (
    SELECT
        TRIM(customer_id::TEXT) AS cid,
        COUNT(*)                AS copies,
        COUNT(DISTINCT ROW(gender, date_of_birth, city, state, email,
                           occupation, annual_income, join_date, credit_score)::TEXT)
                                AS versions
    FROM raw.customers
    WHERE customer_id IS NOT NULL
    GROUP BY 1
)
SELECT
    CASE
        WHEN copies = 1   THEN 'single_row'
        WHEN versions = 1 THEN 'exact_reload'
        ELSE 'changed_between_loads'
    END                AS id_type,
    COUNT(*)           AS ids,
    SUM(copies)        AS total_rows,
    MAX(copies)        AS max_copies
FROM per_id
GROUP BY 1
ORDER BY ids DESC;

-- 4.4 Five ids whose values changed between loads (spot which columns drift)
WITH changed AS (
    SELECT TRIM(customer_id::TEXT) AS cid
    FROM raw.customers
    WHERE customer_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT ROW(gender, date_of_birth, city, state, email,
                              occupation, annual_income, join_date, credit_score)::TEXT) > 1
    LIMIT 5
)
SELECT c.*
FROM raw.customers c
JOIN changed ch ON TRIM(c.customer_id::TEXT) = ch.cid
ORDER BY ch.cid, c._loaded_at;


-- ============================================================
-- STEP 5: CATEGORICALS
-- For each column: (a) values as stored, (b) values that would merge after
-- trim + collapse spaces + Title Case (these are the dirty variants).
-- ============================================================

-- 5.1 gender: values as stored
SELECT
    COALESCE(gender_raw, '<NULL>') AS raw_value,
    COUNT(*)                       AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.customers_probe
GROUP BY gender_raw
ORDER BY row_count DESC;

-- 5.2 gender: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(gender_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT gender_raw)                                 AS raw_variants,
    array_agg(DISTINCT gender_raw)                             AS raw_values,
    COUNT(*)                                                   AS row_count
FROM exploration.customers_probe
WHERE gender_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT gender_raw) > 1
ORDER BY row_count DESC;

-- 5.3 occupation: values as stored
SELECT
    COALESCE(occupation_raw, '<NULL>') AS raw_value,
    COUNT(*)                           AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.customers_probe
GROUP BY occupation_raw
ORDER BY row_count DESC;

-- 5.4 occupation: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(occupation_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT occupation_raw)                                 AS raw_variants,
    array_agg(DISTINCT occupation_raw)                             AS raw_values,
    COUNT(*)                                                       AS row_count
FROM exploration.customers_probe
WHERE occupation_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT occupation_raw) > 1
ORDER BY row_count DESC;

-- 5.5 state: values as stored
SELECT
    COALESCE(state_raw, '<NULL>') AS raw_value,
    COUNT(*)                      AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.customers_probe
GROUP BY state_raw
ORDER BY row_count DESC;

-- 5.6 state: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(state_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT state_raw)                                 AS raw_variants,
    array_agg(DISTINCT state_raw)                             AS raw_values,
    COUNT(*)                                                  AS row_count
FROM exploration.customers_probe
WHERE state_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT state_raw) > 1
ORDER BY row_count DESC;

-- 5.7 city: how many, and the most common (full list can be long)
SELECT
    COUNT(DISTINCT city_raw)                                              AS distinct_raw,
    COUNT(DISTINCT INITCAP(regexp_replace(TRIM(city_raw), '\s+', ' ', 'g'))) AS distinct_cleaned
FROM exploration.customers_probe;

SELECT
    COALESCE(city_raw, '<NULL>') AS raw_value,
    COUNT(*)                     AS row_count
FROM exploration.customers_probe
GROUP BY city_raw
ORDER BY row_count DESC
LIMIT 100;

-- 5.8 city: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(city_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT city_raw)                                 AS raw_variants,
    array_agg(DISTINCT city_raw)                             AS raw_values,
    COUNT(*)                                                 AS row_count
FROM exploration.customers_probe
WHERE city_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT city_raw) > 1
ORDER BY row_count DESC
LIMIT 100;

-- 5.9 city in more than one state (real for some names, a typo signal for others)
SELECT
    INITCAP(TRIM(city_raw))                         AS city,
    COUNT(DISTINCT INITCAP(TRIM(state_raw)))        AS states,
    array_agg(DISTINCT INITCAP(TRIM(state_raw)))    AS state_list,
    COUNT(*)                                        AS row_count
FROM exploration.customers_probe
WHERE city_raw IS NOT NULL
  AND state_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT INITCAP(TRIM(state_raw))) > 1
ORDER BY states DESC, row_count DESC
LIMIT 100;


-- ============================================================
-- STEP 6: DATES (date_of_birth, join_date)
-- ============================================================

-- 6.1 Shape of the raw text (reveals mixed formats and time parts)
SELECT
    'date_of_birth' AS column_name,
    translate(TRIM(dob_raw), '0123456789', '9999999999') AS shape,
    COUNT(*)        AS row_count,
    MIN(dob_raw)    AS example_min,
    MAX(dob_raw)    AS example_max
FROM exploration.customers_probe
GROUP BY 2
UNION ALL
SELECT
    'join_date',
    translate(TRIM(join_raw), '0123456789', '9999999999'),
    COUNT(*),
    MIN(join_raw),
    MAX(join_raw)
FROM exploration.customers_probe
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 6.2 date_of_birth: validity and range
SELECT
    COUNT(*)                                                      AS total_rows,
    COUNT(*) FILTER (WHERE dob_raw IS NULL OR dob_raw ~ '^\s*$')  AS missing,
    COUNT(*) FILTER (WHERE dob_raw !~ '^\s*$' AND dob IS NULL)    AS unparsable,
    MIN(dob)                                                      AS min_dob,
    MAX(dob)                                                      AS max_dob,
    COUNT(*) FILTER (WHERE dob > CURRENT_DATE)                    AS in_future,
    COUNT(*) FILTER (WHERE dob > CURRENT_DATE - INTERVAL '18 years') AS under_18_or_future,
    COUNT(*) FILTER (WHERE dob < CURRENT_DATE - INTERVAL '100 years') AS over_100
FROM exploration.customers_probe;

-- 6.3 join_date: validity and range
SELECT
    COUNT(*)                                                      AS total_rows,
    COUNT(*) FILTER (WHERE join_raw IS NULL OR join_raw ~ '^\s*$') AS missing,
    COUNT(*) FILTER (WHERE join_raw !~ '^\s*$' AND jd IS NULL)    AS unparsable,
    MIN(jd)                                                       AS min_join,
    MAX(jd)                                                       AS max_join,
    COUNT(*) FILTER (WHERE jd > CURRENT_DATE)                     AS in_future,
    COUNT(*) FILTER (WHERE jd < DATE '2000-01-01')                AS before_2000
FROM exploration.customers_probe;

-- 6.4 Spread: customers per join year and per birth decade
SELECT
    EXTRACT(YEAR FROM jd)::INT AS join_year,
    COUNT(*)                   AS customers
FROM exploration.customers_probe
WHERE jd IS NOT NULL
GROUP BY 1
ORDER BY 1;

SELECT
    (EXTRACT(YEAR FROM dob)::INT / 10) * 10 AS birth_decade,
    COUNT(*)                                AS customers
FROM exploration.customers_probe
WHERE dob IS NOT NULL
GROUP BY 1
ORDER BY 1;


-- ============================================================
-- STEP 7: NUMERICS (annual_income, credit_score)
-- non_numeric = text that is not a plain number (commas, currency signs, 'k', words)
-- ============================================================

-- 7.1 annual_income: profile
SELECT
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE income_raw IS NULL OR income_raw ~ '^\s*$') AS missing,
    COUNT(*) FILTER (WHERE income_raw !~ '^\s*$' AND income IS NULL)   AS non_numeric,
    COUNT(*) FILTER (WHERE income < 0)                             AS negative,
    COUNT(*) FILTER (WHERE income = 0)                             AS zero,
    MIN(income)                                                    AS min_income,
    MAX(income)                                                    AS max_income,
    ROUND(AVG(income), 2)                                          AS avg_income,
    ROUND(STDDEV(income), 2)                                       AS stddev_income,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY income)           AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY income)           AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY income)           AS p75,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY income)           AS p99,
    MAX(LENGTH(SPLIT_PART(TRIM(income_raw), '.', 2)))              AS max_decimals
FROM exploration.customers_probe;

-- 7.2 annual_income: the text values that are not numbers
SELECT
    income_raw,
    COUNT(*) AS row_count
FROM exploration.customers_probe
WHERE income_raw !~ '^\s*$'
  AND income IS NULL
GROUP BY income_raw
ORDER BY row_count DESC
LIMIT 50;

-- 7.3 annual_income: outlier fences (IQR rule on positive values)
WITH q AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY income) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY income) AS q3
    FROM exploration.customers_probe
    WHERE income > 0
)
SELECT
    q.q1,
    q.q3,
    q.q3 - q.q1                                   AS iqr,
    q.q1 - 1.5 * (q.q3 - q.q1)                    AS lower_fence,
    q.q3 + 1.5 * (q.q3 - q.q1)                    AS upper_fence,
    (SELECT COUNT(*) FROM exploration.customers_probe p
     WHERE p.income > q.q3 + 1.5 * (q.q3 - q.q1)) AS rows_above_fence
FROM q;

-- 7.4 annual_income: order of magnitude (spots monthly vs annual or unit mix ups)
SELECT
    FLOOR(LOG(income))::INT AS power_of_10,
    COUNT(*)                AS row_count,
    MIN(income)             AS min_income,
    MAX(income)             AS max_income
FROM exploration.customers_probe
WHERE income > 0
GROUP BY 1
ORDER BY 1;

-- 7.5 annual_income: extremes
(SELECT 'highest' AS side, customer_id_raw, income FROM exploration.customers_probe
 WHERE income IS NOT NULL ORDER BY income DESC LIMIT 20)
UNION ALL
(SELECT 'lowest', customer_id_raw, income FROM exploration.customers_probe
 WHERE income IS NOT NULL ORDER BY income ASC LIMIT 20);

-- 7.6 credit_score: profile
SELECT
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE score_raw IS NULL OR score_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE score_raw !~ '^\s*$' AND score IS NULL)     AS non_numeric,
    COUNT(*) FILTER (WHERE score <> TRUNC(score))                  AS non_integer,
    COUNT(*) FILTER (WHERE score < 300 OR score > 900)             AS outside_300_900,
    MIN(score)                                                     AS min_score,
    MAX(score)                                                     AS max_score,
    ROUND(AVG(score), 2)                                           AS avg_score,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY score)            AS median
FROM exploration.customers_probe;

-- 7.7 credit_score: the text values that are not numbers
SELECT
    score_raw,
    COUNT(*) AS row_count
FROM exploration.customers_probe
WHERE score_raw !~ '^\s*$'
  AND score IS NULL
GROUP BY score_raw
ORDER BY row_count DESC
LIMIT 50;

-- 7.8 credit_score: distribution in buckets of 50
SELECT
    (FLOOR(score / 50) * 50)::INT AS bucket_start,
    COUNT(*)                      AS row_count
FROM exploration.customers_probe
WHERE score IS NOT NULL
GROUP BY 1
ORDER BY 1;


-- ============================================================
-- STEP 8: EMAIL
-- ============================================================

-- 8.1 Profile
SELECT
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE email_raw IS NULL OR email_raw ~ '^\s*$') AS missing,
    COUNT(*) FILTER (WHERE email_raw !~ '^\s*$'
                       AND TRIM(email_raw) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
                                                                   AS invalid_format,
    COUNT(*) FILTER (WHERE email_raw ~ '^\s|\s$')                  AS padded,
    COUNT(*) FILTER (WHERE email_raw <> LOWER(email_raw))          AS has_uppercase,
    COUNT(DISTINCT email_raw)                                      AS distinct_raw,
    COUNT(DISTINCT LOWER(TRIM(email_raw)))                         AS distinct_cleaned
FROM exploration.customers_probe;

-- 8.2 Malformed emails
SELECT
    email_raw,
    COUNT(*) AS row_count
FROM exploration.customers_probe
WHERE email_raw !~ '^\s*$'
  AND TRIM(email_raw) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
GROUP BY email_raw
ORDER BY row_count DESC
LIMIT 50;

-- 8.3 Duplicate emails on the CLEANED value
-- distinct_customers = 1  -> the same customer reloaded
-- distinct_customers > 1  -> one email shared by different customers
SELECT
    LOWER(TRIM(email_raw))                AS email_clean,
    COUNT(*)                              AS row_count,
    COUNT(DISTINCT TRIM(customer_id_raw)) AS distinct_customers
FROM exploration.customers_probe
WHERE email_raw !~ '^\s*$'
GROUP BY 1
HAVING COUNT(*) > 1
ORDER BY distinct_customers DESC, row_count DESC
LIMIT 50;

-- 8.4 How many emails are shared by different customers
SELECT COUNT(*) AS emails_shared_by_multiple_customers
FROM (
    SELECT LOWER(TRIM(email_raw))
    FROM exploration.customers_probe
    WHERE email_raw !~ '^\s*$'
    GROUP BY 1
    HAVING COUNT(DISTINCT TRIM(customer_id_raw)) > 1
) x;

-- 8.5 Top domains (typos like gmial.com show up as tiny domains)
SELECT
    LOWER(SPLIT_PART(TRIM(email_raw), '@', 2)) AS domain,
    COUNT(*)                                   AS row_count
FROM exploration.customers_probe
WHERE email_raw LIKE '%@%'
GROUP BY 1
ORDER BY row_count DESC
LIMIT 30;


-- ============================================================
-- STEP 9: CROSS CHECKS (rules that span columns)
-- ============================================================

-- 9.1 Dates against each other
SELECT
    COUNT(*) FILTER (WHERE jd < dob)                          AS joined_before_birth,
    COUNT(*) FILTER (WHERE jd < dob + INTERVAL '18 years')    AS joined_before_18
FROM exploration.customers_probe
WHERE dob IS NOT NULL
  AND jd  IS NOT NULL;

-- 9.2 Occupation against age, income and score (do the groups make sense?)
SELECT
    INITCAP(regexp_replace(TRIM(occupation_raw), '\s+', ' ', 'g')) AS occupation,
    COUNT(*)                                                       AS customers,
    MIN(EXTRACT(YEAR FROM AGE(CURRENT_DATE, dob)))::INT            AS min_age,
    ROUND(AVG(EXTRACT(YEAR FROM AGE(CURRENT_DATE, dob)))::NUMERIC, 1) AS avg_age,
    MAX(EXTRACT(YEAR FROM AGE(CURRENT_DATE, dob)))::INT            AS max_age,
    MIN(income)                                                    AS min_income,
    ROUND(AVG(income), 2)                                          AS avg_income,
    MAX(income)                                                    AS max_income,
    ROUND(AVG(score), 1)                                           AS avg_score
FROM exploration.customers_probe
WHERE occupation_raw IS NOT NULL
GROUP BY 1
ORDER BY customers DESC;

-- 9.3 Does credit score move with income? (corr near 0 suggests random or synthetic data)
SELECT ROUND(CORR(income, score)::NUMERIC, 3) AS corr_income_score
FROM exploration.customers_probe
WHERE income > 0
  AND score BETWEEN 300 AND 900;


-- ============================================================
-- STEP 10: METADATA COLUMNS
-- ============================================================

-- 10.1 One row per load batch
SELECT
    _batch_id,
    COUNT(*)                      AS row_count,
    COUNT(DISTINCT customer_id)   AS distinct_ids,
    MIN(_loaded_at)               AS first_loaded,
    MAX(_loaded_at)               AS last_loaded
FROM raw.customers
GROUP BY _batch_id
ORDER BY first_loaded;

-- 10.2 Shape of the timestamp columns (mixed formats show up as extra rows)
SELECT
    'created_at' AS column_name,
    translate(created_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(created_at::TEXT) AS min_value,
    MAX(created_at::TEXT) AS max_value
FROM raw.customers
GROUP BY 2
UNION ALL
SELECT
    'loaded_at',
    translate(loaded_at::TEXT, '0123456789', '9999999999'),
    COUNT(*),
    MIN(loaded_at::TEXT),
    MAX(loaded_at::TEXT)
FROM raw.customers
GROUP BY 2
UNION ALL
SELECT
    '_loaded_at',
    translate(_loaded_at::TEXT, '0123456789', '9999999999'),
    COUNT(*),
    MIN(_loaded_at::TEXT),
    MAX(_loaded_at::TEXT)
FROM raw.customers
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 10.3 Ids that appear in more than one batch (drives the dedupe rule)
SELECT COUNT(*) AS ids_in_multiple_batches
FROM (
    SELECT TRIM(customer_id::TEXT)
    FROM raw.customers
    WHERE customer_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT _batch_id) > 1
) x;


-- ============================================================
-- STEP 11: RULE IMPACT
-- Rows each candidate cleaning rule would reject or NULL out.
-- Use this list to decide the rules in the staging procedure.
-- ============================================================

WITH t AS (
    SELECT COUNT(*) AS total FROM exploration.customers_probe
)
SELECT
    r.rule,
    r.failing_rows,
    ROUND(100.0 * r.failing_rows / t.total, 2) AS pct_of_rows
FROM t
CROSS JOIN LATERAL (VALUES
    ('customer_id missing or not 1-18 digits (row would be dropped)',
        (SELECT COUNT(*) FROM exploration.customers_probe
         WHERE customer_id_raw IS NULL OR TRIM(customer_id_raw) !~ '^[0-9]{1,18}$')),
    ('surplus duplicate rows per customer_id (dedupe removes these)',
        (SELECT COUNT(*) - COUNT(DISTINCT TRIM(customer_id_raw)) FROM exploration.customers_probe)),
    ('date_of_birth missing or invalid',
        (SELECT COUNT(*) FROM exploration.customers_probe WHERE dob IS NULL)),
    ('date_of_birth gives age under 18 or in the future',
        (SELECT COUNT(*) FROM exploration.customers_probe WHERE dob > CURRENT_DATE - INTERVAL '18 years')),
    ('date_of_birth gives age over 100',
        (SELECT COUNT(*) FROM exploration.customers_probe WHERE dob < CURRENT_DATE - INTERVAL '100 years')),
    ('join_date missing, invalid, before 2000 or in the future',
        (SELECT COUNT(*) FROM exploration.customers_probe
         WHERE jd IS NULL OR jd < DATE '2000-01-01' OR jd > CURRENT_DATE)),
    ('join_date before 18th birthday',
        (SELECT COUNT(*) FROM exploration.customers_probe
         WHERE dob IS NOT NULL AND jd IS NOT NULL
           AND jd < dob + INTERVAL '18 years')),
    ('email missing or malformed',
        (SELECT COUNT(*) FROM exploration.customers_probe
         WHERE email_raw IS NULL
            OR TRIM(email_raw) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
    ('annual_income not numeric or not greater than 0',
        (SELECT COUNT(*) FROM exploration.customers_probe WHERE income IS NULL OR income <= 0)),
    ('credit_score not numeric or outside 300-900',
        (SELECT COUNT(*) FROM exploration.customers_probe
         WHERE score IS NULL OR score < 300 OR score > 900))
) AS r(rule, failing_rows)
ORDER BY r.failing_rows DESC;
