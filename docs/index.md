# Banking Delta Lakehouse

Daily pipeline: MySQL, MongoDB and Databricks `public` → PySpark → PostgreSQL
(landing → staging → analytics → marts) → Databricks Delta. Airflow orchestrates,
stored procedures transform, and SQL data-quality suites gate every layer.

| | |
| --- | --- |
| Start here | [Quickstart](QUICKSTART.md) — run the project locally |
| Blueprint | [Architecture](ARCHITECTURE.md) — layers, flow, gates, contracts |
| Day to day | [Runbook](RUNBOOK.md) · [Troubleshooting](TROUBLESHOOTING.md) |
| Business findings | [Insights](INSIGHTS.md) |

This site is built from `main` and served at the GitHub Pages root. Branch
previews live under `/preview/<branch>/` (`dev`, `staging`, `qa`) and carry a
`noindex` tag so they stay out of search engines.
