# .devcontainer

GitHub Codespaces / VS Code dev container for running the Streamlit dashboard
without a local Python setup.

## Contents

- `devcontainer.json` - container image, VS Code extensions, port forwarding,
  dependency install command, and the auto-start command for Streamlit.

## What it does

1. Builds from `mcr.microsoft.com/devcontainers/python:1-3.11-bookworm`.
2. Installs Python dependencies from `requirements.txt` (root or `dashboard/`),
   plus Streamlit.
3. Forwards port 8501 and opens it as "Application".
4. On attach, starts `streamlit run dashboard/app.py` with CORS/XSRF disabled
   for the Codespace proxy.
5. Opens `README.md` and `dashboard/app.py` in the editor.

## Required secrets

The dashboard connects to Databricks. Provide these before running:

- `DATABRICKS_HOST`
- `DATABRICKS_HTTP_PATH`
- `DATABRICKS_TOKEN`
- `DATABRICKS_CATALOG` (default `banking_transactions_db`)
- `DATABRICKS_MARTS_SCHEMA` (default `marts`)

Set them as Codespace secrets, or create `dashboard/.streamlit/secrets.toml`
from `dashboard/.streamlit/secrets.toml.example`.

## Local use

Open the repo in VS Code and choose "Reopen in Container", or launch a
Codespace from GitHub. The dashboard will be available on port 8501.

## Notes

- Python version in the container is 3.11, while the project targets 3.13.
  Use the container for dashboard preview only; run the pipeline locally.
- If dependencies change, rebuild the container to pick them up.
