#!/usr/bin/env bash
set -euo pipefail

echo "Running airflow db migrate..."
airflow db migrate

echo "Creating admin user if not exists..."
airflow users create \
  --username "${AIRFLOW_ADMIN_USERNAME:-admin}" \
  --password "${AIRFLOW_ADMIN_PASSWORD:-admin}" \
  --firstname "${AIRFLOW_ADMIN_FIRSTNAME:-Admin}" \
  --lastname "${AIRFLOW_ADMIN_LASTNAME:-User}" \
  --role Admin \
  --email "${AIRFLOW_ADMIN_EMAIL:-admin@example.com}" || echo "Admin user may already exist"

echo "Setting up pools..."
airflow pools set spark_jvm 3 "Spark JVMs: the three extracts may run at once (publish runs later, alone)" || true

echo "Init complete"
