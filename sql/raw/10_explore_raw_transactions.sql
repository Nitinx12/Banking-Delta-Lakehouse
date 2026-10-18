-- ============================================================
-- Script:   explore_raw_transactions.sql
-- Purpose:  Profile raw.transactions BEFORE writing its staging procedure
-- Database: banking_delta (schema: raw)
-- Writes:   Only exploration.transactions_probe (dropped and rebuilt on every run).
--           raw.transactions is never modified.
-- Run: psql -U postgres -d banking_delta -f .\sql\exploration\explore_raw_transactions.sql
--      or run it one step at a time in your SQL client and read each result.
--
-- Needs: staging.try_date(TEXT) from 06_sp_load_card_transactions_scd1.sql
-- Key:   transaction_id
-- Note:  Likely the largest table, run step by step.
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
--   txn_date from 2000-01-01 to today
--   amount greater than 0
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
FROM raw.transactions;

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
  AND table_name   = 'transactions'
ORDER BY ordinal_position;

-- 1.2 First rows as stored
SELECT *
FROM raw.transactions
LIMIT 50;

-- 1.3 Random rows (first rows are rarely representative)
SELECT *
FROM raw.transactions
ORDER BY random()
LIMIT 50;


-- ============================================================
-- STEP 2: WORKING SET
-- Parse dates, numbers and flags once; every later step reads this table.
-- Columns: <col>_raw is the stored text, <col> is the parsed value.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS exploration;

DROP TABLE IF EXISTS exploration.transactions_probe;

CREATE TABLE exploration.transactions_probe AS
SELECT
    c.transaction_id::TEXT AS transaction_id_raw,
    c.account_id::TEXT AS account_id_raw,
    c.txn_type::TEXT AS txn_type_raw,
    c.channel::TEXT AS channel_raw,
    c.merchant_category::TEXT AS merchant_category_raw,
    c.txn_date::TEXT AS txn_date_raw,
    c.amount::TEXT AS amount_raw,
    d.txn_date,
    n.amount,
    CURRENT_TIMESTAMP AS probed_at
FROM raw.transactions c
CROSS JOIN LATERAL (
    SELECT
        staging.try_date(LEFT(TRIM(c.txn_date::TEXT), 10)) AS txn_date
    OFFSET 0
) d
CROSS JOIN LATERAL (
    SELECT
        CASE WHEN TRIM(c.amount::TEXT) ~ '^-?[0-9]+(\.[0-9]+)?$'
             THEN TRIM(c.amount::TEXT)::NUMERIC END AS amount
    OFFSET 0
) n;

COMMENT ON TABLE exploration.transactions_probe IS
    'Parsed snapshot of raw.transactions for data exploration. Rebuilt by explore_raw_transactions.sql, safe to drop.';

ANALYZE exploration.transactions_probe;


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
FROM raw.transactions c
CROSS JOIN LATERAL jsonb_each_text(to_jsonb(c)) AS j(key, value)
GROUP BY j.key
ORDER BY pct_missing DESC, column_name;


-- ============================================================
-- STEP 4: KEYS (transaction_id and foreign keys)
-- ============================================================

-- 4.1 Key health
SELECT
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE transaction_id_raw IS NULL
                        OR TRIM(transaction_id_raw) = '')                   AS missing_key,
    COUNT(*) FILTER (WHERE TRIM(transaction_id_raw) <> ''
                       AND TRIM(transaction_id_raw) !~ '^[0-9]{1,18}$')     AS invalid_format,
    COUNT(DISTINCT TRIM(transaction_id_raw))                                AS distinct_keys,
    COUNT(transaction_id_raw) - COUNT(DISTINCT TRIM(transaction_id_raw))               AS surplus_rows,
    MIN(LENGTH(TRIM(transaction_id_raw)))                                   AS min_len,
    MAX(LENGTH(TRIM(transaction_id_raw)))                                   AS max_len
FROM exploration.transactions_probe;

-- 4.2 Malformed keys (what do they look like?)
SELECT
    transaction_id_raw,
    COUNT(*) AS row_count
FROM exploration.transactions_probe
WHERE transaction_id_raw IS NOT NULL
  AND TRIM(transaction_id_raw) !~ '^[0-9]{1,18}$'
GROUP BY transaction_id_raw
ORDER BY row_count DESC
LIMIT 50;

-- 4.3 Duplicated keys: harmless reloads or real changes between loads?
WITH per_key AS (
    SELECT
        TRIM(transaction_id::TEXT) AS k,
        COUNT(*)        AS copies,
        COUNT(DISTINCT ROW(account_id, txn_type, channel, merchant_category, txn_date, amount)::TEXT) AS versions
    FROM raw.transactions
    WHERE transaction_id IS NOT NULL
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
    SELECT TRIM(transaction_id::TEXT) AS k
    FROM raw.transactions
    WHERE transaction_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT ROW(account_id, txn_type, channel, merchant_category, txn_date, amount)::TEXT) > 1
    LIMIT 5
)
SELECT c.*
FROM raw.transactions c
JOIN changed ch ON TRIM(c.transaction_id::TEXT) = ch.k
ORDER BY ch.k, c._loaded_at;

-- 4.5 Foreign keys: missing, malformed, and ids with no parent row in raw
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
FROM exploration.transactions_probe p
LEFT JOIN (
    SELECT DISTINCT TRIM(account_id::TEXT) AS id
    FROM raw.accounts
) r ON r.id = TRIM(p.account_id_raw);


-- ============================================================
-- STEP 5: CATEGORICALS AND TEXT
-- Categoricals: values as stored, then the variants that merge after
-- trim + collapse spaces + Title Case (these are the dirty variants).
-- ============================================================

-- 5.1 txn_type: values as stored
SELECT
    COALESCE(txn_type_raw, '<NULL>') AS raw_value,
    COUNT(*)                    AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.transactions_probe
GROUP BY txn_type_raw
ORDER BY row_count DESC
LIMIT 100;

-- 5.2 txn_type: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(txn_type_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT txn_type_raw)                                 AS raw_variants,
    array_agg(DISTINCT txn_type_raw)                             AS raw_values,
    COUNT(*)                                                AS row_count
FROM exploration.transactions_probe
WHERE txn_type_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT txn_type_raw) > 1
ORDER BY row_count DESC
LIMIT 100;

-- 5.3 channel: values as stored
SELECT
    COALESCE(channel_raw, '<NULL>') AS raw_value,
    COUNT(*)                    AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.transactions_probe
GROUP BY channel_raw
ORDER BY row_count DESC
LIMIT 100;

-- 5.4 channel: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(channel_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT channel_raw)                                 AS raw_variants,
    array_agg(DISTINCT channel_raw)                             AS raw_values,
    COUNT(*)                                                AS row_count
FROM exploration.transactions_probe
WHERE channel_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT channel_raw) > 1
ORDER BY row_count DESC
LIMIT 100;

-- 5.5 merchant_category: values as stored
SELECT
    COALESCE(merchant_category_raw, '<NULL>') AS raw_value,
    COUNT(*)                    AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM exploration.transactions_probe
GROUP BY merchant_category_raw
ORDER BY row_count DESC
LIMIT 100;

-- 5.6 merchant_category: variants that collapse after cleaning
SELECT
    INITCAP(regexp_replace(TRIM(merchant_category_raw), '\s+', ' ', 'g')) AS cleaned_value,
    COUNT(DISTINCT merchant_category_raw)                                 AS raw_variants,
    array_agg(DISTINCT merchant_category_raw)                             AS raw_values,
    COUNT(*)                                                AS row_count
FROM exploration.transactions_probe
WHERE merchant_category_raw IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT merchant_category_raw) > 1
ORDER BY row_count DESC
LIMIT 100;


-- ============================================================
-- STEP 6: DATES
-- ============================================================

-- 6.1 Shape of the raw text (reveals mixed formats and time parts)
SELECT
    'txn_date'        AS column_name,
    translate(TRIM(txn_date_raw), '0123456789', '9999999999') AS shape,
    COUNT(*)     AS row_count,
    MIN(txn_date_raw) AS example_min,
    MAX(txn_date_raw) AS example_max
FROM exploration.transactions_probe
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 6.2 Validity and range
SELECT
    'txn_date'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE txn_date_raw IS NULL OR txn_date_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE txn_date_raw !~ '^\s*$' AND txn_date IS NULL)    AS unparsable,
    MIN(txn_date)                                                       AS min_date,
    MAX(txn_date)                                                       AS max_date,
    COUNT(*) FILTER (WHERE txn_date > CURRENT_DATE)                     AS in_future,
    DATE '2000-01-01'                                                    AS min_allowed,
    COUNT(*) FILTER (WHERE txn_date < DATE '2000-01-01')                      AS before_min_allowed
FROM exploration.transactions_probe;

-- 6.3 Rows per year
SELECT
    'txn_date'                      AS column_name,
    EXTRACT(YEAR FROM txn_date)::INT AS yr,
    COUNT(*)                   AS row_count
FROM exploration.transactions_probe
WHERE txn_date IS NOT NULL
GROUP BY 2
ORDER BY column_name, yr;


-- ============================================================
-- STEP 7: NUMERICS AND FLAGS
-- non_numeric = text that is not a plain number (commas, currency signs, 'k', words).
-- ============================================================

-- 7.1 amount: profile
SELECT
    'amount'                                                          AS column_name,
    COUNT(*)                                                       AS total_rows,
    COUNT(*) FILTER (WHERE amount_raw IS NULL OR amount_raw ~ '^\s*$')   AS missing,
    COUNT(*) FILTER (WHERE amount_raw !~ '^\s*$' AND amount IS NULL)    AS non_numeric,
    COUNT(*) FILTER (WHERE amount < 0)                                AS negative,
    COUNT(*) FILTER (WHERE amount = 0)                                AS zero,
    MIN(amount)                                                       AS min_value,
    MAX(amount)                                                       AS max_value,
    ROUND(AVG(amount), 2)                                             AS avg_value,
    ROUND(STDDEV(amount), 2)                                          AS stddev_value,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY amount)              AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY amount)              AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY amount)              AS p75,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY amount)              AS p99,
    MAX(LENGTH(SPLIT_PART(TRIM(amount_raw), '.', 2)))                 AS max_decimals
FROM exploration.transactions_probe;

-- 7.2 amount: the text values that are not numbers
SELECT
    amount_raw,
    COUNT(*) AS row_count
FROM exploration.transactions_probe
WHERE amount_raw !~ '^\s*$'
  AND amount IS NULL
GROUP BY amount_raw
ORDER BY row_count DESC
LIMIT 50;

-- 7.3 amount: outlier fences (IQR rule on positive values)
WITH q AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY amount) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY amount) AS q3
    FROM exploration.transactions_probe
    WHERE amount > 0
)
SELECT
    q.q1,
    q.q3,
    q.q3 - q.q1                                   AS iqr,
    q.q1 - 1.5 * (q.q3 - q.q1)                    AS lower_fence,
    q.q3 + 1.5 * (q.q3 - q.q1)                    AS upper_fence,
    (SELECT COUNT(*) FROM exploration.transactions_probe p
     WHERE p.amount > q.q3 + 1.5 * (q.q3 - q.q1))    AS rows_above_fence
FROM q;

-- 7.4 amount: order of magnitude (spots unit mix ups)
SELECT
    FLOOR(LOG(amount))::INT AS power_of_10,
    COUNT(*)             AS row_count,
    MIN(amount)             AS min_value,
    MAX(amount)             AS max_value
FROM exploration.transactions_probe
WHERE amount > 0
GROUP BY 1
ORDER BY 1;

-- 7.5 amount: extremes
(SELECT 'highest' AS side, transaction_id_raw, amount FROM exploration.transactions_probe
 WHERE amount IS NOT NULL ORDER BY amount DESC LIMIT 20)
UNION ALL
(SELECT 'lowest', transaction_id_raw, amount FROM exploration.transactions_probe
 WHERE amount IS NOT NULL ORDER BY amount ASC LIMIT 20);


-- ============================================================
-- STEP 8: CROSS CHECKS (rules that span columns)
-- ============================================================

-- 8.1 amount by txn_type (do the groups make sense?)
SELECT
    INITCAP(regexp_replace(TRIM(txn_type_raw), '\s+', ' ', 'g')) AS txn_type,
    COUNT(*)                                                  AS row_count,
    COUNT(amount)                                               AS numeric_rows,
    MIN(amount)                                                 AS min_value,
    ROUND(AVG(amount), 2)                                       AS avg_value,
    MAX(amount)                                                 AS max_value
FROM exploration.transactions_probe
WHERE txn_type_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC;

-- 8.2 amount by channel (do the groups make sense?)
SELECT
    INITCAP(regexp_replace(TRIM(channel_raw), '\s+', ' ', 'g')) AS channel,
    COUNT(*)                                                  AS row_count,
    COUNT(amount)                                               AS numeric_rows,
    MIN(amount)                                                 AS min_value,
    ROUND(AVG(amount), 2)                                       AS avg_value,
    MAX(amount)                                                 AS max_value
FROM exploration.transactions_probe
WHERE channel_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC;

-- 8.3 amount by merchant_category (do the groups make sense?)
SELECT
    INITCAP(regexp_replace(TRIM(merchant_category_raw), '\s+', ' ', 'g')) AS merchant_category,
    COUNT(*)                                                  AS row_count,
    COUNT(amount)                                               AS numeric_rows,
    MIN(amount)                                                 AS min_value,
    ROUND(AVG(amount), 2)                                       AS avg_value,
    MAX(amount)                                                 AS max_value
FROM exploration.transactions_probe
WHERE merchant_category_raw IS NOT NULL
GROUP BY 1
ORDER BY row_count DESC;

-- 8.4 Transaction type against channel
SELECT
    INITCAP(regexp_replace(TRIM(txn_type_raw), '\s+', ' ', 'g')) AS txn_type,
    INITCAP(regexp_replace(TRIM(channel_raw), '\s+', ' ', 'g'))  AS channel,
    COUNT(*)                                                      AS row_count
FROM exploration.transactions_probe
GROUP BY 1, 2
ORDER BY 1, row_count DESC;

-- 8.5 Possible duplicate transactions (same account, date, type, amount under different ids)
SELECT COUNT(*) AS duplicate_groups, COALESCE(SUM(copies), 0) AS rows_involved
FROM (
    SELECT COUNT(DISTINCT TRIM(transaction_id_raw)) AS copies
    FROM exploration.transactions_probe
    GROUP BY TRIM(account_id_raw), txn_date, LOWER(TRIM(txn_type_raw)), amount
    HAVING COUNT(DISTINCT TRIM(transaction_id_raw)) > 1
) x;


-- ============================================================
-- STEP 9: METADATA COLUMNS
-- ============================================================

-- 9.1 One row per load batch
SELECT
    _batch_id,
    COUNT(*)                 AS row_count,
    COUNT(DISTINCT transaction_id)      AS distinct_keys,
    MIN(_loaded_at)          AS first_loaded,
    MAX(_loaded_at)          AS last_loaded
FROM raw.transactions
GROUP BY _batch_id
ORDER BY first_loaded;

-- 9.2 Shape of the timestamp columns (mixed formats show up as extra rows)
SELECT
    'created_at' AS column_name,
    translate(created_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(created_at::TEXT) AS min_value,
    MAX(created_at::TEXT) AS max_value
FROM raw.transactions
GROUP BY 2
UNION ALL
SELECT
    'loaded_at' AS column_name,
    translate(loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(loaded_at::TEXT) AS min_value,
    MAX(loaded_at::TEXT) AS max_value
FROM raw.transactions
GROUP BY 2
UNION ALL
SELECT
    '_loaded_at' AS column_name,
    translate(_loaded_at::TEXT, '0123456789', '9999999999') AS shape,
    COUNT(*) AS row_count,
    MIN(_loaded_at::TEXT) AS min_value,
    MAX(_loaded_at::TEXT) AS max_value
FROM raw.transactions
GROUP BY 2
ORDER BY column_name, row_count DESC;

-- 9.3 Keys that appear in more than one batch (drives the dedupe rule)
SELECT COUNT(*) AS keys_in_multiple_batches
FROM (
    SELECT TRIM(transaction_id::TEXT)
    FROM raw.transactions
    WHERE transaction_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT _batch_id) > 1
) x;


-- ============================================================
-- STEP 10: RULE IMPACT
-- Rows each candidate cleaning rule would reject or NULL out.
-- Use this list to decide the rules in the staging procedure.
-- ============================================================

WITH t AS (
    SELECT COUNT(*) AS total FROM exploration.transactions_probe
)
SELECT
    r.rule,
    r.failing_rows,
    ROUND(100.0 * r.failing_rows / NULLIF(t.total, 0), 2) AS pct_of_rows
FROM t
CROSS JOIN LATERAL (VALUES
    ('transaction_id missing or not 1-18 digits (row would be dropped)',
        (SELECT COUNT(*) FROM exploration.transactions_probe WHERE transaction_id_raw IS NULL OR TRIM(transaction_id_raw) !~ '^[0-9]{1,18}$')),
    ('surplus duplicate rows per transaction_id (dedupe removes these)',
        (SELECT COUNT(transaction_id_raw) - COUNT(DISTINCT TRIM(transaction_id_raw)) FROM exploration.transactions_probe)),
    ('account_id present but not 1-18 digits',
        (SELECT COUNT(*) FROM exploration.transactions_probe WHERE TRIM(account_id_raw) <> '' AND TRIM(account_id_raw) !~ '^[0-9]{1,18}$')),
    ('account_id has no parent row in raw.accounts',
        (SELECT COUNT(*) FROM exploration.transactions_probe p WHERE TRIM(p.account_id_raw) ~ '^[0-9]{1,18}$' AND NOT EXISTS (SELECT 1 FROM raw.accounts r WHERE TRIM(r.account_id::TEXT) = TRIM(p.account_id_raw)))),
    ('txn_date present but not a valid date',
        (SELECT COUNT(*) FROM exploration.transactions_probe WHERE txn_date_raw !~ '^\s*$' AND txn_date IS NULL)),
    ('txn_date before 2000-01-01',
        (SELECT COUNT(*) FROM exploration.transactions_probe WHERE txn_date < DATE '2000-01-01')),
    ('txn_date in the future',
        (SELECT COUNT(*) FROM exploration.transactions_probe WHERE txn_date > CURRENT_DATE)),
    ('amount present but not numeric',
        (SELECT COUNT(*) FROM exploration.transactions_probe WHERE amount_raw !~ '^\s*$' AND amount IS NULL)),
    ('amount zero or negative',
        (SELECT COUNT(*) FROM exploration.transactions_probe WHERE amount <= 0))
) AS r(rule, failing_rows)
ORDER BY r.failing_rows DESC;
