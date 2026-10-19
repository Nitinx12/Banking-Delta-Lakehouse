# Banking Delta — Executive Dashboard

Streamlit + Plotly dashboard that queries the **Databricks `marts` schema live** through a
SQL warehouse (no extracts, no cached copies — every chart is a `SELECT` against Delta).

## Pages

| Page | Mart | Charts |
|---|---|---|
| Overview (`app.py`) | `mart_kpi_monthly` | KPI cards, dual-axis lines, area, diverging MoM bars |
| KPI Explorer | `mart_kpi_monthly` | Small-multiple trends, quarterly rollup, MoM bars |
| Customers | `mart_customer_360` | Treemap, donuts, income/credit scatter, top-activity bars |
| Loans | `mart_loan_portfolio` | Treemap, vintage lines, band bars, risk scatter |
| Cards | `mart_card_fraud` | Spend-vs-fraud lines, fraud treemap, tier×merchant heatmaps |
| Branches | `mart_branch_performance` | League bars, region treemap, efficiency scatter |

## Run locally

```bash
cd dashboard
python -m venv .venv && .venv\Scripts\activate    # or: python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .streamlit/secrets.toml.example .streamlit/secrets.toml   # then fill in real values
streamlit run app.py
```

Secrets are read from `.streamlit/secrets.toml` first, then from environment variables
(`DATABRICKS_HOST`, `DATABRICKS_HTTP_PATH`, `DATABRICKS_TOKEN`, `DATABRICKS_CATALOG`,
`DATABRICKS_MARTS_SCHEMA`).

## Realtime behaviour

- Every loader in `helpers/marts.py` runs a live `SELECT` via `lib/db.py`.
- Queries are cached for 5 minutes (`lib/db.py::DEFAULT_TTL_SECONDS`) to protect the warehouse.
- The sidebar offers auto-refresh (1/5/15 min) and a **Refresh now** button that clears the cache.

## Docker

```bash
cd dashboard
docker build -t banking-dashboard .
docker run -p 8501:8501 banking-dashboard
```

Provide secrets via environment variables or mount `.streamlit/secrets.toml`.

## Layout

```
dashboard/
├── app.py                  # Executive overview
├── pages/                  # KPI, customers, loans, cards, branches
├── lib/
│   ├── db.py               # Databricks SQL connection + cached queries
│   ├── charts.py           # Plotly figure builders (treemap, lines, bars, heatmaps…)
│   └── filter.py           # Sidebar controls and filter helpers
├── helpers/
│   ├── marts.py            # Typed loaders for each marts table
│   ├── components.py       # KPI cards, headers, tables, auto-refresh fragment
│   ├── theme.py            # Brand palette + ₹ / % formatting
│   └── plotly_template.py  # Shared Plotly template
└── .streamlit/             # config.toml, secrets.toml (git-ignored)
```
