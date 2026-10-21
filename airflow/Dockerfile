# syntax=docker/dockerfile:1.7
ARG AIRFLOW_VERSION
ARG PYTHON_VERSION=3.13
FROM apache/airflow:${AIRFLOW_VERSION}-python${PYTHON_VERSION}

ARG AIRFLOW_VERSION
ARG PYTHON_VERSION
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="banking-delta-airflow" \
      org.opencontainers.image.revision="${GIT_SHA}"

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends default-jre-headless curl procps \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && java -version

# TeX toolchain for the report builder (shared package list)
COPY reports/apt-packages.txt /tmp/apt-packages.txt
RUN apt-get update \
 && xargs -a /tmp/apt-packages.txt apt-get install -y --no-install-recommends \
 && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/apt-packages.txt

RUN mkdir -p /opt/banking /opt/banking/.spark /opt/banking/logs /opt/banking-venv /opt/airflow/logs /opt/airflow/include /opt/airflow/dags /opt/airflow/scripts \
 && chown -R airflow:0 /opt/banking /opt/banking-venv /opt/airflow/logs /opt/airflow/include /opt/airflow/dags /opt/airflow/scripts

ENV GIT_SHA=${GIT_SHA} \
    BANKING_HOME=/opt/banking \
    BANKING_VENV=/opt/banking-venv \
    BANKING_PYTHON=/opt/banking-venv/bin/python \
    PROJECT_ROOT=/opt/banking \
    PYTHONUTF8=1 \
    NO_COLOR=1

USER airflow

# Airflow-side extras
COPY --chown=airflow:0 airflow/requirements-airflow.txt /tmp/requirements-airflow.txt
RUN pip install --no-cache-dir "apache-airflow==${AIRFLOW_VERSION}" -r /tmp/requirements-airflow.txt \
    --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"

# Project venv
COPY --chown=airflow:0 pyproject.toml uv.lock requirements.txt /opt/banking/
USER root
RUN chown -R airflow:0 /opt/banking
USER airflow
RUN (command -v uv >/dev/null || pip install --no-cache-dir uv) \
 && uv venv /opt/banking-venv --python "$(command -v python)" \
 && cd /opt/banking \
 && UV_PROJECT_ENVIRONMENT=/opt/banking-venv uv sync --frozen --no-dev --no-install-project 2>&1 | tail -20

# Reports runtime (jinja2, jsonschema, pyyaml, matplotlib, psycopg2-binary, python-dotenv)
COPY --chown=airflow:0 reports/ /opt/banking/reports/
RUN cd /opt/banking && UV_PROJECT_ENVIRONMENT=/opt/banking-venv uv sync --frozen --group reports 2>&1 | tail -10

# Project code
COPY --chown=airflow:0 main.py /opt/banking/main.py
COPY --chown=airflow:0 src/     /opt/banking/src/
COPY --chown=airflow:0 scripts/ /opt/banking/scripts/
COPY --chown=airflow:0 sql/     /opt/banking/sql/
COPY --chown=airflow:0 tests/data-quality/ /opt/banking/tests/data-quality/
COPY --chown=airflow:0 conf/    /opt/banking/conf/

# Airflow files
COPY --chown=airflow:0 airflow/dags/    /opt/airflow/dags/
COPY --chown=airflow:0 airflow/include/ /opt/airflow/include/
COPY --chown=airflow:0 airflow/scripts/ /opt/airflow/scripts/

RUN chmod +x /opt/airflow/scripts/*.sh 2>/dev/null || true \
 && java -version \
 && /opt/banking-venv/bin/python -c "import pyspark; print('pyspark ok')" 2>&1 | tail -2 \
 && airflow version 2>&1 | tail -1
