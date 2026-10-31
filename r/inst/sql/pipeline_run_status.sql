-- Latest pipeline run and the outcome of its marts table runs.
WITH latest AS (
    SELECT pipeline_run_id, status
    FROM audit.pipeline_runs
    ORDER BY COALESCE(ended_at, started_at) DESC
    LIMIT 1
)
SELECT
    latest.status,
    COUNT(tr.processing_layer) AS marts_runs,
    SUM(CASE WHEN tr.status <> 'SUCCESS' THEN 1 ELSE 0 END) AS marts_failed
FROM latest
LEFT JOIN audit.table_runs AS tr
    ON tr.pipeline_run_id = latest.pipeline_run_id
   AND tr.processing_layer = 'marts'
GROUP BY latest.status;
