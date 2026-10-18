-- ============================================================
-- Script:   explore_raw_support_tickets.sql
-- Purpose:  Profile raw.support_tickets BEFORE writing its staging procedure
-- Database: banking_delta (schema: raw)
-- Writes:   Only exploration.support_tickets_probe (dropped and rebuilt on every run).
--           raw.support_tickets is never modified.
-- Run: psql -U postgres -d banking_delta -f .\sql\exploration\explore_raw_support_tickets.sql
--      or run it one step at a time in your SQL client and read each result.
--
-- Needs: staging.try_date(TEXT) from 06_sp_load_card_transactions_scd1.sql
-- Key:   ticket_id
-- Note:  Landed from MongoDB, so _id exists.
-- Note:  ticket_id is expected to be digits only, step 4 shows if it is not.
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
--   date_opened from 2000-01-01 to today
--   date_resolved from 2000-01-01 to today
--   satisfaction_score between 1 and 5, whole numbers
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
FROM raw.support_tickets;

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
  AND table_name   = 'support_tickets'
ORDER BY ordinal_position;

-- 1.2 First rows as stored
SELECT *
FROM raw.support_tickets
LIMIT 50;

-- 1.3 Random rows (first rows are rarely representative)
SELECT *
FROM raw.support_tickets
ORDER BY random()
LIMIT 50;


-- ============================================================
-- STEP 2: WORKING SET
-- Parse dates, numbers and flags once; every later step reads this table.
-- Columns: <col>_raw is the stored text, <col> is the parsed value.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS exploration;

DROP TABLE IF EXISTS exploration.support_tickets_probe;

CREATE TABLE exploration.support_tickets_probe AS
SELECT
    c.ticket_id::TEXT AS ticket_id_raw,
    c.customer_id::TEXT AS customer_id_raw,
    c.issue_type::TEXT AS issue_type_raw,
    c.status::TEXT AS status_raw,
    c.date_opened::TEXT AS date_opened_raw,
    c.date_resolved::TEXT AS date_resolved_raw,
    c.satisfaction_score::TEXT AS satisfaction_score_raw,
    d.date_opened,
    d.date_resolved,
    n.satisfaction_score,
    CURRENT_TIMESTAMP AS probed_at
FROM raw.support_tickets c
CROSS JOIN LATERAL (
    SELECT
        staging.try_date(LEFT(TRIM(c.date_opened::TEXT), 10)) AS date_opened,
        staging.try_date(LEFT(TRIM(c.date_resolved::TEXT), 10)) AS date_resolved
    OFFSET 0
) d
CROSS JOIN LATERAL (
    SELECT
        CASE WHEN TRIM(c.satisfaction_score::TEXT) ~ '^-?[0-9]+(\.[0-9]+)?$'
             THEN TRIM(c.satisfaction_score::TEXT)::NUMERIC END AS satisfaction_score
    OFFSET 0
) n;

COMMENT ON TABLE exploration.support_tickets_probe IS
    'Parsed snapshot of raw.support_tickets for data exploration. Rebuilt by explore_raw_support_tickets.sql, safe to drop.';

ANALYZE exploration.support_tickets_probe;


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
FROM raw.support_tickets c
CROSS JOIN LATERAL jsonb_each_text(to_jsonb(c)) AS j(key, value)
GROUP BY j.key
ORDER BY pct_missing DESC, column_name;


-- ============================================================
-- STEP 4: KEYS (ticket_id and foreign keys)
-- ============================================================

-- 4.1 Key health
SELECT
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE ticket_id_raw IS NULL
                        OR TRIM(ticket_id_raw) = '')                   AS missing_key,
    COUNT(*) FILTER (WHERE TRIM(ticket_id_raw) <> ''
                       AND TRIM(ticket_id_raw) !~ '^[0-9]{1,18}$')     AS invalid_format,
    COUNT(DISTINCT TRIM(ticket_id_raw))                                AS distinct_keys,
    COUNT(ticket_id_raw) - COUNT(DISTINCT TRIM(ticket_id_raw))               AS surplus_rows,
    MIN(LENGTH(TRIM(ticket_id_raw)))                                   AS min_len,
    MAX(LENGTH(TRIM(ticket_id_raw)))                                   AS max_len
FROM exploration.support_tickets_probe;

-- 4.2 Malformed keys (what do they look like?)
SELECT
    ticket_id_raw,
    COUNT(*) AS row_count
FROM exploration.support_tickets_probe
WHERE ticket_id_raw IS NOT NULL
  AND TRIM(ticket_id_raw) !~ '^[0-9]{1,18}$'
GROUP BY ticket_id_raw
ORDER BY row_count DESC
LIMIT 50;

-- 4.3 Duplicated keys: harmless reloads or real changes between loads?
WITH per_key AS (
    SELECT
        TRIM(ticket_id::TEXT) AS k,
        COUNT(*)        AS copies,
        COUNT(DISTINCT ROW(customer_id, issue_type, status, date_opened, date_resolved, satisfaction_score)::TEXT) AS versions
    FROM raw.support_tickets
    WHERE ticket_id IS NOT NULL
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
    SELECT TRIM(ticket_id::TEXT) AS k
    FROM raw.support_tickets
    WHERE ticket_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT ROW(customer_id, issue_type, status, date_opened, date_resolved, satisfaction_score)::TEXT) > 1
    LIMIT 5
)
SELECT c.*
FROM raw.support_tickets c
JOIN changed ch ON TRIM(c.ticket_id::TEXT) = ch.k
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
FROM exploration.support_tickets_probe p
LEFT JOIN (
    SELECT DISTINCT TRIM(customer_id::TEXT) AS id
    FROM raw.customers
) r ON r.id = TRIM(p.customer_id_raw);


-- ============================================================
-- STEP 5: CATEGORICALS AND TEXT
-- Categoricals: values as stored, then the variants that merge after
-- trim + collapse spaces + Title Case (these are the dirty variants).
-- ============================================================

-- 5.1 issue_type: values as stored
SELECT
    COALESCE(issue_type_raw, '<NULL>') AS raw_value,
    COUNT(*)                    AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.support_tickets_probe
GROUP BY issue_type_raw
ORDER BY row_count DESC
LIMIT 100;

-- 5.2 issue_type: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(issue_type_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT issue_type_raw)                                 AS raw_variants,
    array_agg(DISTINCT issue_type_raw)                             AS raw_values,
    COUNT(*)                                                AS row_count
FROM exploration.support_tickets_probe
WHERE issue_type_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT issue_type_raw) > 1
ORDER BY row_count DESC
LIMIT 100;

-- 5.3 status: values as stored
SELECT
    COALESCE(status_raw, '<NULL>') AS raw_value,
    COUNT(*)                    AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.support_tickets_probe
GROUP BY status_raw
ORDER BY row_count DESC
LIMIT 100;

-- 5.4 status: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(status_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT status_raw)                                 AS raw_variants,
    array_agg(DISTINCT status_raw)                             AS raw_values,
    COUNT(*)                                                AS row_count
FROM exploration.support_tickets_probe
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
    'date_opened'        AS column_name,
    translate(TRIM(date_opened_raw), '0123456789', '9999999999') AS shape,
    COUNT(*)     AS row_count,
    MIN(date_opened_raw) AS example_min,
    MAX(date_opened_raw) AS example_max
FROM exploration.support_tickets_probe
GROUP BY 2
UNION ALL
SELECT
    'date_resolved'        AS column_name,
    translate(TRIM(date_resolved_raw), '0123456789', '9999999999') AS shape,
    COUNT(*)     AS row_count,
    MIN(date_resolved_raw) AS example_min,
    MAX(date_resolved_raw) AS example_max
FROM exploration.support_tickets_probe
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 6.2 Validity and range
SELECT
    'date_opened'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE date_opened_raw IS NULL OR date_opened_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE date_opened_raw !~ '^\s*$' AND date_opened IS NULL)    AS unparsable,
    MIN(date_opened)                                                       AS min_date,
    MAX(date_opened)                                                       AS max_date,
    COUNT(*) FILTER (WHERE date_opened > CURRENT_DATE)                     AS in_future,
    DATE '2000-01-01'                                                    AS min_allowed,
    COUNT(*) FILTER (WHERE date_opened < DATE '2000-01-01')                      AS before_min_allowed
FROM exploration.support_tickets_probe
UNION ALL
SELECT
    'date_resolved'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE date_resolved_raw IS NULL OR date_resolved_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE date_resolved_raw !~ '^\s*$' AND date_resolved IS NULL)    AS unparsable,
    MIN(date_resolved)                                                       AS min_date,
    MAX(date_resolved)                                                       AS max_date,
    COUNT(*) FILTER (WHERE date_resolved > CURRENT_DATE)                     AS in_future,
    DATE '2000-01-01'                                                    AS min_allowed,
    COUNT(*) FILTER (WHERE date_resolved < DATE '2000-01-01')                      AS before_min_allowed
FROM exploration.support_tickets_probe;

-- 6.3 Rows per year
SELECT
    'date_opened'                      AS column_name,
    EXTRACT(YEAR FROM date_opened)::INT AS yr,
    COUNT(*)                   AS row_count
FROM exploration.support_tickets_probe
WHERE date_opened IS NOT NULL
GROUP BY 2
UNION ALL
SELECT
    'date_resolved'                      AS column_name,
    EXTRACT(YEAR FROM date_resolved)::INT AS yr,
    COUNT(*)                   AS row_count
FROM exploration.support_tickets_probe
WHERE date_resolved IS NOT NULL
GROUP BY 2
ORDER BY column_name, yr;


-- ============================================================
-- STEP 7: NUMERICS AND FLAGS
-- non_numeric = text that is not a plain number (commas, currency signs, 'k', words).
-- ============================================================

-- 7.1 satisfaction_score: profile
SELECT
    'satisfaction_score'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE satisfaction_score_raw IS NULL OR satisfaction_score_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE satisfaction_score_raw !~ '^\s*$' AND satisfaction_score IS NULL)    AS non_numeric,
    COUNT(*) FILTER (WHERE satisfaction_score < 0)                                AS negative,
    COUNT(*) FILTER (WHERE satisfaction_score = 0)                                AS zero,
    MIN(satisfaction_score)                                                       AS min_value,
    MAX(satisfaction_score)                                                       AS max_value,
    ROUND(AVG(satisfaction_score), 2)                                             AS avg_value,
    ROUND(STDDEV(satisfaction_score), 2)                                          AS stddev_value,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY satisfaction_score)              AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY satisfaction_score)              AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY satisfaction_score)              AS p75,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY satisfaction_score)              AS p99,
    MAX(LENGTH(SPLIT_PART(TRIM(satisfaction_score_raw), '.', 2)))                 AS max_decimals,
    COUNT(*) FILTER (WHERE satisfaction_score <> TRUNC(satisfaction_score)) AS non_integer,
    COUNT(*) FILTER (WHERE satisfaction_score < 1 OR satisfaction_score > 5) AS outside_expected_range
FROM exploration.support_tickets_probe;

-- 7.2 satisfaction_score: the text values that are not numbers
SELECT
    satisfaction_score_raw,
    COUNT(*) AS row_count
FROM exploration.support_tickets_probe
WHERE satisfaction_score_raw !~ '^\s*$'
  AND satisfaction_score IS NULL
GROUP BY satisfaction_score_raw
ORDER BY row_count DESC
LIMIT 50;

-- 7.3 satisfaction_score: outlier fences (IQR rule on positive values)
WITH q AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY satisfaction_score) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY satisfaction_score) AS q3
    FROM exploration.support_tickets_probe
    WHERE satisfaction_score > 0
)
SELECT
    q.q1,
    q.q3,
    q.q3 - q.q1                                   AS iqr,
    q.q1 - 1.5 * (q.q3 - q.q1)                    AS lower_fence,
    q.q3 + 1.5 * (q.q3 - q.q1)                    AS upper_fence,
    (SELECT COUNT(*) FROM exploration.support_tickets_probe p
     WHERE p.satisfaction_score > q.q3 + 1.5 * (q.q3 - q.q1))    AS rows_above_fence
FROM q;

-- 7.4 satisfaction_score: extremes
(SELECT 'highest' AS side, ticket_id_raw, satisfaction_score FROM exploration.support_tickets_probe
 WHERE satisfaction_score IS NOT NULL ORDER BY satisfaction_score DESC LIMIT 20)
UNION ALL
(SELECT 'lowest', ticket_id_raw, satisfaction_score FROM exploration.support_tickets_probe
 WHERE satisfaction_score IS NOT NULL ORDER BY satisfaction_score ASC LIMIT 20);


-- ============================================================
-- STEP 8: CROSS CHECKS (rules that span columns)
-- ============================================================

-- 8.1 satisfaction_score by issue_type (do the groups make sense?)
SELECT
    INITCAP(regexp_replace(TRIM(issue_type_raw), '\s+', ' ', 'g')) AS issue_type,
    COUNT(*)                                                  AS row_count,
    COUNT(satisfaction_score)                                               AS numeric_rows,
    MIN(satisfaction_score)                                                 AS min_value,
    ROUND(AVG(satisfaction_score), 2)                                       AS avg_value,
    MAX(satisfaction_score)                                                 AS max_value
FROM exploration.support_tickets_probe
WHERE issue_type_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC;

-- 8.2 satisfaction_score by status (do the groups make sense?)
SELECT
    INITCAP(regexp_replace(TRIM(status_raw), '\s+', ' ', 'g')) AS status,
    COUNT(*)                                                  AS row_count,
    COUNT(satisfaction_score)                                               AS numeric_rows,
    MIN(satisfaction_score)                                                 AS min_value,
    ROUND(AVG(satisfaction_score), 2)                                       AS avg_value,
    MAX(satisfaction_score)                                                 AS max_value
FROM exploration.support_tickets_probe
WHERE status_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC;

-- 8.3 Resolved before opened
SELECT
    COUNT(*) FILTER (WHERE date_resolved < date_opened) AS resolved_before_opened,
    COUNT(*) FILTER (WHERE date_resolved IS NOT NULL
                       AND date_opened IS NOT NULL)     AS rows_with_both_dates
FROM exploration.support_tickets_probe;

-- 8.4 Status against resolution date and score (do open tickets have a resolved date?)
SELECT
    INITCAP(regexp_replace(TRIM(status_raw), '\s+', ' ', 'g')) AS status,
    COUNT(*)                                                    AS row_count,
    COUNT(date_resolved)                                        AS with_resolved_date,
    COUNT(satisfaction_score)                                   AS with_score
FROM exploration.support_tickets_probe
GROUP BY 1
ORDER BY row_count DESC;

-- 8.5 Days to resolve
SELECT
    COUNT(*)                                                         AS resolved_rows,
    MIN(date_resolved - date_opened)                                 AS min_days,
    ROUND(AVG(date_resolved - date_opened), 1)                       AS avg_days,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY date_resolved - date_opened) AS median_days,
    MAX(date_resolved - date_opened)                                 AS max_days
FROM exploration.support_tickets_probe
WHERE date_resolved IS NOT NULL
  AND date_opened   IS NOT NULL;


-- ============================================================
-- STEP 9: METADATA COLUMNS
-- ============================================================

-- 9.1 One row per load batch
SELECT
    _batch_id,
    COUNT(*)                 AS row_count,
    COUNT(DISTINCT ticket_id)      AS distinct_keys,
    MIN(_loaded_at)          AS first_loaded,
    MAX(_loaded_at)          AS last_loaded
FROM raw.support_tickets
GROUP BY _batch_id
ORDER BY first_loaded;

-- 9.2 Shape of the timestamp columns (mixed formats show up as extra rows)
SELECT
    'created_at' AS column_name,
    translate(created_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(created_at::TEXT) AS min_value,
    MAX(created_at::TEXT) AS max_value
FROM raw.support_tickets
GROUP BY 2
UNION ALL
SELECT
    'loaded_at' AS column_name,
    translate(loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(loaded_at::TEXT) AS min_value,
    MAX(loaded_at::TEXT) AS max_value
FROM raw.support_tickets
GROUP BY 2
UNION ALL
SELECT
    '_loaded_at' AS column_name,
    translate(_loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(_loaded_at::TEXT) AS min_value,
    MAX(_loaded_at::TEXT) AS max_value
FROM raw.support_tickets
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 9.3 Keys that appear in more than one batch (drives the dedupe rule)
SELECT COUNT(*) AS keys_in_multiple_batches
FROM (
    SELECT TRIM(ticket_id::TEXT)
    FROM raw.support_tickets
    WHERE ticket_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT _batch_id) > 1
) x;

-- 9.4 MongoDB _id: present and unique per document?
SELECT
    COUNT(*)                   AS total_rows,
    COUNT(_id)                 AS with_id,
    COUNT(DISTINCT _id::TEXT)  AS distinct_ids
FROM raw.support_tickets;


-- ============================================================
-- STEP 10: RULE IMPACT
-- Rows each candidate cleaning rule would reject or NULL out.
-- Use this list to decide the rules in the staging procedure.
-- ============================================================

WITH t AS (
    SELECT COUNT(*) AS total FROM exploration.support_tickets_probe
)
SELECT
    r.rule,
    r.failing_rows,
    ROUND(100.0 * r.failing_rows / NULLIF(t.total, 0), 2) AS pct_of_rows
FROM t
CROSS JOIN LATERAL (VALUES
    ('ticket_id missing or not 1-18 digits (row would be dropped)',
        (SELECT COUNT(*) FROM exploration.support_tickets_probe WHERE ticket_id_raw IS NULL OR TRIM(ticket_id_raw) !~ '^[0-9]{1,18}$')),
    ('surplus duplicate rows per ticket_id (dedupe removes these)',
        (SELECT COUNT(ticket_id_raw) - COUNT(DISTINCT TRIM(ticket_id_raw)) FROM exploration.support_tickets_probe)),
    ('customer_id present but not 1-18 digits',
        (SELECT COUNT(*) FROM exploration.support_tickets_probe WHERE TRIM(customer_id_raw) <> '' AND TRIM(customer_id_raw) !~ '^[0-9]{1,18}$')),
    ('customer_id has no parent row in raw.customers',
        (SELECT COUNT(*) FROM exploration.support_tickets_probe p WHERE TRIM(p.customer_id_raw) ~ '^[0-9]{1,18}$' AND NOT EXISTS (SELECT 1 FROM raw.customers r WHERE TRIM(r.customer_id::TEXT) = TRIM(p.customer_id_raw)))),
    ('date_opened present but not a valid date',
        (SELECT COUNT(*) FROM exploration.support_tickets_probe WHERE date_opened_raw !~ '^\s*$' AND date_opened IS NULL)),
    ('date_opened before 2000-01-01',
        (SELECT COUNT(*) FROM exploration.support_tickets_probe WHERE date_opened < DATE '2000-01-01')),
    ('date_opened in the future',
        (SELECT COUNT(*) FROM exploration.support_tickets_probe WHERE date_opened > CURRENT_DATE)),
    ('date_resolved present but not a valid date',
        (SELECT COUNT(*) FROM exploration.support_tickets_probe WHERE date_resolved_raw !~ '^\s*$' AND date_resolved IS NULL)),
    ('date_resolved before 2000-01-01',
        (SELECT COUNT(*) FROM exploration.support_tickets_probe WHERE date_resolved < DATE '2000-01-01')),
    ('date_resolved in the future',
        (SELECT COUNT(*) FROM exploration.support_tickets_probe WHERE date_resolved > CURRENT_DATE)),
    ('satisfaction_score present but not numeric',
        (SELECT COUNT(*) FROM exploration.support_tickets_probe WHERE satisfaction_score_raw !~ '^\s*$' AND satisfaction_score IS NULL)),
    ('satisfaction_score outside 1 to 5',
        (SELECT COUNT(*) FROM exploration.support_tickets_probe WHERE satisfaction_score < 1 OR satisfaction_score > 5)),
    ('satisfaction_score not a whole number',
        (SELECT COUNT(*) FROM exploration.support_tickets_probe WHERE satisfaction_score <> TRUNC(satisfaction_score))),
    ('date_resolved before date_opened',
        (SELECT COUNT(*) FROM exploration.support_tickets_probe WHERE date_resolved < date_opened))
) AS r(rule, failing_rows)
ORDER BY r.failing_rows DESC;
