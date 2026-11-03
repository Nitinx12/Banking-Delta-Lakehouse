---
name: bootstrap-from-csv
description: Load the repo's bundled data/raw CSV snapshots into the raw schema when MySQL, MongoDB or Databricks are unreachable.
trigger: no source access, load csv, bootstrap raw, data dir, load-raw-csv, fresh clone data
---

# Bootstrap raw from the bundled CSVs

The repository ships gzipped CSV snapshots of all 10 source tables under
`data/raw/{mysql,mongo,databricks}/` (112 MB total). A fresh clone can build the
entire `raw` layer from them — no MySQL, MongoDB or Databricks credentials
needed — and then run staging/analytics/marts/DQ normally.

## Layout

```
data/raw/
├── mysql/        accounts.csv.gz branches.csv.gz cards.csv.gz customers.csv.gz employees.csv.gz
├── mongo/        support_tickets.csv.gz card_transactions.csv.gz
└── databricks/   loans.csv.gz loan_payments.csv.gz transactions.csv.gz
```

- Folder names map to registry sources: `mysql_source`→`mysql`,
  `mongodb_source`→`mongo`, `databricks_source`→`databricks`
  (see `FOLDER`/`SOURCE_FOLDERS` in the scripts).
- Plain `*.csv` files (a fresh export) take precedence over the shipped `.csv.gz`
  when both exist; plain CSVs and `*.part` temps are gitignored.

## Loading (the script other users run)

```bash
make load-raw-csv                                # Windows: tasks.bat load-raw-csv
make load-raw-csv ARGS="--dry-run"               # plan only, no DB connection
make load-raw-csv ARGS="--tables accounts"       # subset by target table
make load-raw-csv ARGS="--batch-rows 10000"      # smaller COPY batches
```

What `scripts/load_raw_csv.py` does, per table, **in one transaction**:

1. Reads the CSV header with polars (`pl.read_csv`), loads rows in batches of
   strings (all columns read as `String` — no re-typing, no leading-zero or
   float corruption).
2. Creates the table if missing from the **column contract**
   (`contracts/<source>/<table>.json`) plus the raw metadata contract columns
   `_batch_id text NOT NULL`, `_loaded_at timestamptz NOT NULL`.
3. Adds any CSV/contract columns the table is still missing (unknown columns are
   added as `text`, never `float`).
4. `TRUNCATE` then `COPY ... WITH (FORMAT CSV)` via `copy_expert`, stamping
   `_batch_id` (uuid) and `_loaded_at` (UTC ISO) on every row.

Because each table is truncate-and-replace of the same snapshot, the loader is
idempotent: run it twice, get the same result.

### Requirements

- `.env` with `PG_HOST/PG_PORT/PG_DB/PG_USER/PG_PASS` (schema `raw` is created
  if absent; the script logs the target database before writing).
- `uv sync` done (polars is a declared dependency).

## Regenerating the snapshots (maintainers, needs source creds)

```bash
make export-raw-csv                                # all 10 tables -> data/raw/**/*.csv.gz
python scripts/export_raw_csv.py --sources mysql   # one source
python scripts/export_raw_csv.py --limit 1000      # sample only
```

- Streams each source (SSCursor for Mongo's 3M docs, batched fetches for
  Databricks) straight into gzip; writes `*.csv.gz.part` then renames.
- Column set = `SELECT *` / natural order; the export aborts on mid-scan schema
  drift instead of silently truncating columns.
- After a refresh, commit the changed `.csv.gz` files.

## Typical fresh-clone sequence

```bash
make install
# apply sql/scripts/*.sql in numeric order with psql (see file headers)
make load-raw-csv
make dq-raw && make staging && make dq-staging    # ... continue as usual
```

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `no CSVs found under ...` | snapshots missing — re-clone or run `make export-raw-csv` with creds |
| `CSV is missing required columns` | hand-made CSV lacks a NOT NULL contract column — add the column or fix the file |
| `document schema drift mid-export` (export) | source collection gained/lost keys mid-scan — inspect and re-run |
| type errors during `COPY` | CSV value doesn't parse to the contract/existing column type — check the offending table with `--tables <name>` |
| large memory use | lower `--batch-rows` (default 50 000) |

## Done Checklist

- [ ] `make load-raw-csv` reports row counts matching the source
      (e.g. `card_transactions` = 3 005 000, `transactions` = 2 000 005).
- [ ] `SELECT count(*) FROM raw.<table>;` agrees with the export log.
- [ ] `make dq-raw` passes against the loaded data.
