-- ============================================================
-- Script:   04_explore_raw_cards.sql
-- Purpose:  Profile raw.cards BEFORE writing its staging procedure
-- Database: banking_delta (schema: raw)
-- Writes:   Only exploration.cards_probe (dropped and rebuilt on every run).
--           raw.cards is never modified.
-- Run: psql -U postgres -d banking_delta -f .\sql\raw\04_explore_raw_cards.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS exploration;

DROP TABLE IF EXISTS exploration.cards_probe;

CREATE TABLE exploration.cards_probe AS
SELECT c.*, CURRENT_TIMESTAMP AS probed_at
FROM raw.cards c;

COMMENT ON TABLE exploration.cards_probe IS
    'Parsed snapshot of raw.cards for data exploration. Rebuilt by 04_explore_raw_cards.sql, safe to drop.';

ANALYZE exploration.cards_probe;


-- ============================================================
-- STEP 0: CONTEXT
-- ============================================================

SELECT
    current_database()        AS database_name,
    COUNT(*)                  AS total_rows,
    COUNT(DISTINCT _batch_id) AS batches,
    MIN(_loaded_at)           AS first_loaded,
    MAX(_loaded_at)           AS last_loaded
FROM raw.cards;

SELECT to_regprocedure('staging.try_date(text)') IS NOT NULL AS try_date_available;


-- ============================================================
-- STEP 1: STRUCTURE
-- ============================================================

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

SELECT *
FROM raw.cards
LIMIT 50;

SELECT *
FROM raw.cards
ORDER BY random()
LIMIT 50;


-- ============================================================
-- STEP 2: COLUMN PROFILE
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
FROM raw.cards c
CROSS JOIN LATERAL jsonb_each_text(to_jsonb(c)) AS j(key, value)
GROUP BY j.key
ORDER BY pct_missing DESC, column_name;


-- ============================================================
-- STEP 3: KEY (card_id)
-- ============================================================

SELECT
    COUNT(*)                                                     AS total_rows,
    COUNT(*) FILTER (WHERE card_id::TEXT IS NULL
                        OR TRIM(card_id::TEXT) = '')              AS missing_key,
    COUNT(*) FILTER (WHERE TRIM(card_id::TEXT) <> ''
                       AND TRIM(card_id::TEXT) !~ '^[0-9]{1,18}$')
                                                                 AS invalid_format,
    COUNT(DISTINCT TRIM(card_id::TEXT))                           AS distinct_keys,
    COUNT(*) - COUNT(DISTINCT TRIM(card_id::TEXT))                AS surplus_rows
FROM raw.cards;

SELECT
    TRIM(card_id::TEXT) AS raw_key,
    COUNT(*)           AS row_count
FROM raw.cards
WHERE card_id::TEXT IS NOT NULL
  AND TRIM(card_id::TEXT) !~ '^[0-9]{1,18}$'
GROUP BY 1
ORDER BY row_count DESC
LIMIT 50;


-- ============================================================
-- STEP 4: METADATA
-- ============================================================

SELECT
    _batch_id,
    COUNT(*)        AS row_count,
    MIN(_loaded_at) AS first_loaded,
    MAX(_loaded_at) AS last_loaded
FROM raw.cards
GROUP BY _batch_id
ORDER BY _batch_id;
