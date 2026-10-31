-- Latest marts DQ verdict: failed checks and total checks.
SELECT
    SUM(CASE WHEN status = 'FAIL' THEN 1 ELSE 0 END) AS failures,
    COUNT(*) AS checks
FROM audit.v_dq_latest
WHERE layer = 'marts';
