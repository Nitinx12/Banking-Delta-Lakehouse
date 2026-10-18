-- ============================================================
-- Script:   explore_raw_cards.sql
-- Purpose:  Profile raw.cards BEFORE writing its staging procedure
-- Database: banking_delta (schema: raw)
-- Writes:   Only exploration.cards_probe (dropped and rebuilt on every run).
--           raw.cards is never modified.
-- Run: psql -U postgres -d banking_delta -f .\sql\exploration\explore_raw_cards.sql
--      or run it one step at a time in your SQL client and read each result.
--
-- Needs: staging.try_date(TEXT) from 06_sp_load_card_transactions_scd1.sql
-- Key:   card_id
-- Note:  expiry_date is allowed to be in the future.
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
--   issue_date from 2000-01-01 to today
--   expiry_date from 2000-01-01, future dates allowed
--   credit_limit greater than 0
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
FROM raw.cards;

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
  AND table_name   = 'cards'
ORDER BY ordinal_position;

-- 1.2 First rows as stored
SELECT *
FROM raw.cards
LIMIT 50;

-- 1.3 Random rows (first rows are rarely representative)
SELECT *
FROM raw.cards
ORDER BY random()
LIMIT 50;


-- ============================================================
-- STEP 2: WORKING SET
-- Parse dates, numbers and flags once; every later step reads this table.
-- Columns: <col>_raw is the stored text, <col> is the parsed value.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS exploration;

DROP TABLE IF EXISTS exploration.cards_probe;

CREATE TABLE exploration.cards_probe AS
SELECT
    c.card_id::TEXT AS card_id_raw,
    c.customer_id::TEXT AS customer_id_raw,
    c.account_id::TEXT AS account_id_raw,
    c.card_type::TEXT AS card_type_raw,
    c.status::TEXT AS status_raw,
    c.issue_date::TEXT AS issue_date_raw,
    c.expiry_date::TEXT AS expiry_date_raw,
    c.credit_limit::TEXT AS credit_limit_raw,
    d.issue_date,
    d.expiry_date,
    n.credit_limit,
    CURRENT_TIMESTAMP AS probed_at
FROM raw.cards c
CROSS JOIN LATERAL (
    SELECT
        staging.try_date(LEFT(TRIM(c.issue_date::TEXT), 10)) AS issue_date,
        staging.try_date(LEFT(TRIM(c.expiry_date::TEXT), 10)) AS expiry_date
    OFFSET 0
) d
CROSS JOIN LATERAL (
    SELECT
        CASE WHEN TRIM(c.credit_limit::TEXT) ~ '^-?[0-9]+(\.[0-9]+)?$'
             THEN TRIM(c.credit_limit::TEXT)::NUMERIC END AS credit_limit
    OFFSET 0
) n;

COMMENT ON TABLE exploration.cards_probe IS
    'Parsed snapshot of raw.cards for data exploration. Rebuilt by explore_raw_cards.sql, safe to drop.';

ANALYZE exploration.cards_probe;


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
FROM raw.cards c
CROSS JOIN LATERAL jsonb_each_text(to_jsonb(c)) AS j(key, value)
GROUP BY j.key
ORDER BY pct_missing DESC, column_name;


-- ============================================================
-- STEP 4: KEYS (card_id and foreign keys)
-- ============================================================

-- 4.1 Key health
SELECT
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE card_id_raw IS NULL
                        OR TRIM(card_id_raw) = '')                   AS missing_key,
    COUNT(*) FILTER (WHERE TRIM(card_id_raw) <> ''
                       AND TRIM(card_id_raw) !~ '^[0-9]{1,18}$')     AS invalid_format,
    COUNT(DISTINCT TRIM(card_id_raw))                                AS distinct_keys,
    COUNT(card_id_raw) - COUNT(DISTINCT TRIM(card_id_raw))               AS surplus_rows,
    MIN(LENGTH(TRIM(card_id_raw)))                                   AS min_len,
    MAX(LENGTH(TRIM(card_id_raw)))                                   AS max_len
FROM exploration.cards_probe;

-- 4.2 Malformed keys (what do they look like?)
SELECT
    card_id_raw,
    COUNT(*) AS row_count
FROM exploration.cards_probe
WHERE card_id_raw IS NOT NULL
  AND TRIM(card_id_raw) !~ '^[0-9]{1,18}$'
GROUP BY card_id_raw
ORDER BY row_count DESC
LIMIT 50;

-- 4.3 Duplicated keys: harmless reloads or real changes between loads?
WITH per_key AS (
    SELECT
        TRIM(card_id::TEXT) AS k,
        COUNT(*)        AS copies,
        COUNT(DISTINCT ROW(customer_id, account_id, card_type, status, issue_date, expiry_date, credit_limit)::TEXT) AS versions
    FROM raw.cards
    WHERE card_id IS NOT NULL
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
    SELECT TRIM(card_id::TEXT) AS k
    FROM raw.cards
    WHERE card_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT ROW(customer_id, account_id, card_type, status, issue_date, expiry_date, credit_limit)::TEXT) > 1
    LIMIT 5
)
SELECT c.*
FROM raw.cards c
JOIN changed ch ON TRIM(c.card_id::TEXT) = ch.k
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
FROM exploration.cards_probe p
LEFT JOIN (
    SELECT DISTINCT TRIM(customer_id::TEXT) AS id
    FROM raw.customers
) r ON r.id = TRIM(p.customer_id_raw)
UNION ALL
SELECT
    'account_id'                                                       AS fk_column,
    'raw.accounts.account_id'                                              AS parent,
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE p.account_id_raw IS NULL
                        OR TRIM(p.account_id_raw) = '')                AS missing,
    COUNT(*) FILTER (WHERE TRIM(p.account_id_raw) <> ''
                       AND TRIM(p.account_id_raw) !~ '^[0-9]{1,18}$')  AS invalid_format,
    COUNT(*) FILTER (WHERE TRIM(p.account_id_raw) ~ '^[0-9]{1,18}$'
                       AND r.id IS NULL)                         AS orphan_rows,
    COUNT(DISTINCT TRIM(p.account_id_raw)) FILTER (WHERE TRIM(p.account_id_raw) ~ '^[0-9]{1,18}$'
                                                AND r.id IS NULL) AS orphan_distinct_ids
FROM exploration.cards_probe p
LEFT JOIN (
    SELECT DISTINCT TRIM(account_id::TEXT) AS id
    FROM raw.accounts
) r ON r.id = TRIM(p.account_id_raw);


-- ============================================================
-- STEP 5: CATEGORICALS AND TEXT
-- Categoricals: values as stored, then the variants that merge after
-- trim + collapse spaces + Title Case (these are the dirty variants).
-- ============================================================

-- 5.1 card_type: values as stored
SELECT
    COALESCE(card_type_raw, '<NULL>') AS raw_value,
    COUNT(*)                    AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.cards_probe
GROUP BY card_type_raw
ORDER BY row_count DESC
LIMIT 100;

-- 5.2 card_type: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(card_type_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT card_type_raw)                                 AS raw_variants,
    array_agg(DISTINCT card_type_raw)                             AS raw_values,
    COUNT(*)                                                AS row_count
FROM exploration.cards_probe
WHERE card_type_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT card_type_raw) > 1
ORDER BY row_count DESC
LIMIT 100;

-- 5.3 status: values as stored
SELECT
    COALESCE(status_raw, '<NULL>') AS raw_value,
    COUNT(*)                    AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.cards_probe
GROUP BY status_raw
ORDER BY row_count DESC
LIMIT 100;

-- 5.4 status: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(status_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT status_raw)                                 AS raw_variants,
    array_agg(DISTINCT status_raw)                             AS raw_values,
    COUNT(*)                                                AS row_count
FROM exploration.cards_probe
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
    'issue_date'        AS column_name,
    translate(TRIM(issue_date_raw), '0123456789', '9999999999') AS shape,
    COUNT(*)     AS row_count,
    MIN(issue_date_raw) AS example_min,
    MAX(issue_date_raw) AS example_max
FROM exploration.cards_probe
GROUP BY 2
UNION ALL
SELECT
    'expiry_date'        AS column_name,
    translate(TRIM(expiry_date_raw), '0123456789', '9999999999') AS shape,
    COUNT(*)     AS row_count,
    MIN(expiry_date_raw) AS example_min,
    MAX(expiry_date_raw) AS example_max
FROM exploration.cards_probe
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 6.2 Validity and range
SELECT
    'issue_date'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE issue_date_raw IS NULL OR issue_date_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE issue_date_raw !~ '^\s*$' AND issue_date IS NULL)    AS unparsable,
    MIN(issue_date)                                                       AS min_date,
    MAX(issue_date)                                                       AS max_date,
    COUNT(*) FILTER (WHERE issue_date > CURRENT_DATE)                     AS in_future,
    DATE '2000-01-01'                                                    AS min_allowed,
    COUNT(*) FILTER (WHERE issue_date < DATE '2000-01-01')                      AS before_min_allowed
FROM exploration.cards_probe
UNION ALL
SELECT
    'expiry_date'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE expiry_date_raw IS NULL OR expiry_date_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE expiry_date_raw !~ '^\s*$' AND expiry_date IS NULL)    AS unparsable,
    MIN(expiry_date)                                                       AS min_date,
    MAX(expiry_date)                                                       AS max_date,
    COUNT(*) FILTER (WHERE expiry_date > CURRENT_DATE)                     AS in_future,
    DATE '2000-01-01'                                                    AS min_allowed,
    COUNT(*) FILTER (WHERE expiry_date < DATE '2000-01-01')                      AS before_min_allowed
FROM exploration.cards_probe;

-- 6.3 Rows per year
SELECT
    'issue_date'                      AS column_name,
    EXTRACT(YEAR FROM issue_date)::INT AS yr,
    COUNT(*)                   AS row_count
FROM exploration.cards_probe
WHERE issue_date IS NOT NULL
GROUP BY 2
UNION ALL
SELECT
    'expiry_date'                      AS column_name,
    EXTRACT(YEAR FROM expiry_date)::INT AS yr,
    COUNT(*)                   AS row_count
FROM exploration.cards_probe
WHERE expiry_date IS NOT NULL
GROUP BY 2
ORDER BY column_name, yr;


-- ============================================================
-- STEP 7: NUMERICS AND FLAGS
-- non_numeric = text that is not a plain number (commas, currency signs, 'k', words).
-- ============================================================

-- 7.1 credit_limit: profile
SELECT
    'credit_limit'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE credit_limit_raw IS NULL OR credit_limit_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE credit_limit_raw !~ '^\s*$' AND credit_limit IS NULL)    AS non_numeric,
    COUNT(*) FILTER (WHERE credit_limit < 0)                                AS negative,
    COUNT(*) FILTER (WHERE credit_limit = 0)                                AS zero,
    MIN(credit_limit)                                                       AS min_value,
    MAX(credit_limit)                                                       AS max_value,
    ROUND(AVG(credit_limit), 2)                                             AS avg_value,
    ROUND(STDDEV(credit_limit), 2)                                          AS stddev_value,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY credit_limit)              AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY credit_limit)              AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY credit_limit)              AS p75,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY credit_limit)              AS p99,
    MAX(LENGTH(SPLIT_PART(TRIM(credit_limit_raw), '.', 2)))                 AS max_decimals
FROM exploration.cards_probe;

-- 7.2 credit_limit: the text values that are not numbers
SELECT
    credit_limit_raw,
    COUNT(*) AS row_count
FROM exploration.cards_probe
WHERE credit_limit_raw !~ '^\s*$'
  AND credit_limit IS NULL
GROUP BY credit_limit_raw
ORDER BY row_count DESC
LIMIT 50;

-- 7.3 credit_limit: outlier fences (IQR rule on positive values)
WITH q AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY credit_limit) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY credit_limit) AS q3
    FROM exploration.cards_probe
    WHERE credit_limit > 0
)
SELECT
    q.q1,
    q.q3,
    q.q3 - q.q1                                   AS iqr,
    q.q1 - 1.5 * (q.q3 - q.q1)                    AS lower_fence,
    q.q3 + 1.5 * (q.q3 - q.q1)                    AS upper_fence,
    (SELECT COUNT(*) FROM exploration.cards_probe p
     WHERE p.credit_limit > q.q3 + 1.5 * (q.q3 - q.q1))    AS rows_above_fence
FROM q;

-- 7.4 credit_limit: order of magnitude (spots unit mix ups)
SELECT
    FLOOR(LOG(credit_limit))::INT AS power_of_10,
    COUNT(*)             AS row_count,
    MIN(credit_limit)             AS min_value,
    MAX(credit_limit)             AS max_value
FROM exploration.cards_probe
WHERE credit_limit > 0
GROUP BY 1
ORDER BY 1;

-- 7.5 credit_limit: extremes
(SELECT 'highest' AS side, card_id_raw, credit_limit FROM exploration.cards_probe
 WHERE credit_limit IS NOT NULL ORDER BY credit_limit DESC LIMIT 20)
UNION ALL
(SELECT 'lowest', card_id_raw, credit_limit FROM exploration.cards_probe
 WHERE credit_limit IS NOT NULL ORDER BY credit_limit ASC LIMIT 20);


-- ============================================================
-- STEP 8: CROSS CHECKS (rules that span columns)
-- ============================================================

-- 8.1 credit_limit by card_type (do the groups make sense?)
SELECT
    INITCAP(regexp_replace(TRIM(card_type_raw), '\s+', ' ', 'g')) AS card_type,
    COUNT(*)                                                  AS row_count,
    COUNT(credit_limit)                                               AS numeric_rows,
    MIN(credit_limit)                                                 AS min_value,
    ROUND(AVG(credit_limit), 2)                                       AS avg_value,
    MAX(credit_limit)                                                 AS max_value
FROM exploration.cards_probe
WHERE card_type_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC;

-- 8.2 credit_limit by status (do the groups make sense?)
SELECT
    INITCAP(regexp_replace(TRIM(status_raw), '\s+', ' ', 'g')) AS status,
    COUNT(*)                                                  AS row_count,
    COUNT(credit_limit)                                               AS numeric_rows,
    MIN(credit_limit)                                                 AS min_value,
    ROUND(AVG(credit_limit), 2)                                       AS avg_value,
    MAX(credit_limit)                                                 AS max_value
FROM exploration.cards_probe
WHERE status_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC;

-- 8.3 Expiry against issue date, and expired cards still marked active
SELECT
    COUNT(*) FILTER (WHERE expiry_date < issue_date)                                  AS expiry_before_issue,
    COUNT(*) FILTER (WHERE expiry_date < CURRENT_DATE
                       AND LOWER(TRIM(status_raw)) = 'active')                        AS expired_but_active,
    COUNT(*) FILTER (WHERE issue_date > CURRENT_DATE)                                 AS issued_in_future
FROM exploration.cards_probe;

-- 8.4 Card validity in years (a single value is expected)
SELECT
    EXTRACT(YEAR FROM AGE(expiry_date, issue_date))::INT AS validity_years,
    COUNT(*)                                             AS row_count
FROM exploration.cards_probe
WHERE issue_date IS NOT NULL
  AND expiry_date IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- 8.5 Cards whose account belongs to a different customer (latest account row used)
SELECT
    COUNT(*)                                                    AS matched_cards,
    COUNT(*) FILTER (WHERE a.cid IS DISTINCT FROM TRIM(p.customer_id_raw)) AS account_of_other_customer
FROM exploration.cards_probe p
JOIN (
    SELECT DISTINCT ON (TRIM(account_id::TEXT))
        TRIM(account_id::TEXT)  AS aid,
        TRIM(customer_id::TEXT) AS cid
    FROM raw.accounts
    ORDER BY TRIM(account_id::TEXT), _loaded_at DESC NULLS LAST
) a ON a.aid = TRIM(p.account_id_raw);


-- ============================================================
-- STEP 9: METADATA COLUMNS
-- ============================================================

-- 9.1 One row per load batch
SELECT
    _batch_id,
    COUNT(*)                 AS row_count,
    COUNT(DISTINCT card_id)      AS distinct_keys,
    MIN(_loaded_at)          AS first_loaded,
    MAX(_loaded_at)          AS last_loaded
FROM raw.cards
GROUP BY _batch_id
ORDER BY first_loaded;

-- 9.2 Shape of the timestamp columns (mixed formats show up as extra rows)
SELECT
    'created_at' AS column_name,
    translate(created_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(created_at::TEXT) AS min_value,
    MAX(created_at::TEXT) AS max_value
FROM raw.cards
GROUP BY 2
UNION ALL
SELECT
    'loaded_at' AS column_name,
    translate(loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(loaded_at::TEXT) AS min_value,
    MAX(loaded_at::TEXT) AS max_value
FROM raw.cards
GROUP BY 2
UNION ALL
SELECT
    '_loaded_at' AS column_name,
    translate(_loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(_loaded_at::TEXT) AS min_value,
    MAX(_loaded_at::TEXT) AS max_value
FROM raw.cards
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 9.3 Keys that appear in more than one batch (drives the dedupe rule)
SELECT COUNT(*) AS keys_in_multiple_batches
FROM (
    SELECT TRIM(card_id::TEXT)
    FROM raw.cards
    WHERE card_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT _batch_id) > 1
) x;


-- ============================================================
-- STEP 10: RULE IMPACT
-- Rows each candidate cleaning rule would reject or NULL out.
-- Use this list to decide the rules in the staging procedure.
-- ============================================================

WITH t AS (
    SELECT COUNT(*) AS total FROM exploration.cards_probe
)
SELECT
    r.rule,
    r.failing_rows,
    ROUND(100.0 * r.failing_rows / NULLIF(t.total, 0), 2) AS pct_of_rows
FROM t
CROSS JOIN LATERAL (VALUES
    ('card_id missing or not 1-18 digits (row would be dropped)',
        (SELECT COUNT(*) FROM exploration.cards_probe WHERE card_id_raw IS NULL OR TRIM(card_id_raw) !~ '^[0-9]{1,18}$')),
    ('surplus duplicate rows per card_id (dedupe removes these)',
        (SELECT COUNT(card_id_raw) - COUNT(DISTINCT TRIM(card_id_raw)) FROM exploration.cards_probe)),
    ('customer_id present but not 1-18 digits',
        (SELECT COUNT(*) FROM exploration.cards_probe WHERE TRIM(customer_id_raw) <> '' AND TRIM(customer_id_raw) !~ '^[0-9]{1,18}$')),
    ('customer_id has no parent row in raw.customers',
        (SELECT COUNT(*) FROM exploration.cards_probe p WHERE TRIM(p.customer_id_raw) ~ '^[0-9]{1,18}$' AND NOT EXISTS (SELECT 1 FROM raw.customers r WHERE TRIM(r.customer_id::TEXT) = TRIM(p.customer_id_raw)))),
    ('account_id present but not 1-18 digits',
        (SELECT COUNT(*) FROM exploration.cards_probe WHERE TRIM(account_id_raw) <> '' AND TRIM(account_id_raw) !~ '^[0-9]{1,18}$')),
    ('account_id has no parent row in raw.accounts',
        (SELECT COUNT(*) FROM exploration.cards_probe p WHERE TRIM(p.account_id_raw) ~ '^[0-9]{1,18}$' AND NOT EXISTS (SELECT 1 FROM raw.accounts r WHERE TRIM(r.account_id::TEXT) = TRIM(p.account_id_raw)))),
    ('issue_date present but not a valid date',
        (SELECT COUNT(*) FROM exploration.cards_probe WHERE issue_date_raw !~ '^\s*$' AND issue_date IS NULL)),
    ('issue_date before 2000-01-01',
        (SELECT COUNT(*) FROM exploration.cards_probe WHERE issue_date < DATE '2000-01-01')),
    ('issue_date in the future',
        (SELECT COUNT(*) FROM exploration.cards_probe WHERE issue_date > CURRENT_DATE)),
    ('expiry_date present but not a valid date',
        (SELECT COUNT(*) FROM exploration.cards_probe WHERE expiry_date_raw !~ '^\s*$' AND expiry_date IS NULL)),
    ('expiry_date before 2000-01-01',
        (SELECT COUNT(*) FROM exploration.cards_probe WHERE expiry_date < DATE '2000-01-01')),
    ('credit_limit present but not numeric',
        (SELECT COUNT(*) FROM exploration.cards_probe WHERE credit_limit_raw !~ '^\s*$' AND credit_limit IS NULL)),
    ('credit_limit zero or negative',
        (SELECT COUNT(*) FROM exploration.cards_probe WHERE credit_limit <= 0)),
    ('expiry_date before issue_date',
        (SELECT COUNT(*) FROM exploration.cards_probe WHERE expiry_date < issue_date))
) AS r(rule, failing_rows)
ORDER BY r.failing_rows DESC;
