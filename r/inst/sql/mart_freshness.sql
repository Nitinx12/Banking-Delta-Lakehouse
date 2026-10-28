-- Freshness per mart: row count + max freshness column.
SELECT COUNT(*) AS n, MAX({freshness_col}) AS latest
FROM marts.{mart};
