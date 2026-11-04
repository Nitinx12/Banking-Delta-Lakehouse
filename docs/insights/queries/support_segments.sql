-- Support resolution and satisfaction by issue type from marts.mart_support_performance.
SELECT
    issue_type,
    SUM(ticket_count) AS ticket_count,
    SUM(resolved_count) AS resolved_count,
    ROUND(100.0 * SUM(resolved_count) / NULLIF(SUM(ticket_count), 0), 2) AS resolution_rate_pct,
    ROUND(AVG(avg_satisfaction_score)::numeric, 2) AS avg_satisfaction,
    SUM(low_satisfaction_count) AS low_satisfaction_count
FROM marts.mart_support_performance
GROUP BY issue_type
ORDER BY resolution_rate_pct ASC;
