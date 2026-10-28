ARG R_VERSION=4.5.1
FROM rocker/r-ver:${R_VERSION}

ARG GIT_SHA=unknown
ARG WITH_QUARTO=false

ENV R_OUTPUT_DIR=/app/output

WORKDIR /app

# system deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev libssl-dev libcurl4-openssl-dev libxml2-dev \
  && rm -rf /var/lib/apt/lists/*

# copy dependency files first
COPY DESCRIPTION /app/DESCRIPTION
COPY renv.lock* /app/

RUN Rscript -e 'if (file.exists("renv.lock")) renv::restore(project="/app")' || true

# copy source
COPY . /app

# non-root user
RUN useradd -m -u 10001 appuser && chown -R appuser:appuser /app
USER appuser

ENV GIT_SHA=${GIT_SHA}
ENTRYPOINT ["Rscript", "/app/main.R"]
VOLUME ["/app/output"]
