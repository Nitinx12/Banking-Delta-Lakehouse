# TeX and Python image for the report builder; shell escape stays off.
FROM python:3.13-slim-bookworm

ARG DEBIAN_FRONTEND=noninteractive

COPY reports/apt-packages.txt /tmp/apt-packages.txt
RUN apt-get update \
    && xargs -a /tmp/apt-packages.txt apt-get install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* /tmp/apt-packages.txt

RUN pip install --no-cache-dir \
      jinja2 jsonschema pyyaml matplotlib psycopg2-binary python-dotenv

WORKDIR /work
COPY src/ src/
COPY reports/ reports/

ENV PYTHONPATH=/work
CMD ["python", "-m", "reports.scripts.build", "--all-fixtures"]
