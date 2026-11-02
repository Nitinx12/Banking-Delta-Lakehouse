-- Support SLA and satisfaction from marts.mart_support_performance.
SELECT
    SUM(ticket_count) AS ticket_count,
    SUM(resolved_count) AS resolved_count,
    ROUND(
        100.0 * SUM(resolved_count) / NULLIF(SUM(ticket_count), 0),
        2
    ) AS resolution_rate_pct,
    ROUND(AVG(avg_satisfaction_score)::numeric, 2) AS avg_satisfaction_score,
    SUM(low_satisfaction_count) AS low_satisfaction_count,
    ROUND(
        100.0 * SUM(low_satisfaction_count) / NULLIF(SUM(ticket_count), 0),
        2
    ) AS low_satisfaction_pct
FROM marts.mart_support_performance;
