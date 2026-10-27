"""Publish PostgreSQL marts tables to Databricks marts tables with the same names, incrementally.

Usage:
    python src/jobs/publish_marts.py
    python src/jobs/publish_marts.py --tables mart_kpi_monthly mart_customer_360
    python src/jobs/publish_marts.py --full
    python src/jobs/publish_marts.py --lookback 2 --parallel 6 --finalize

Per table: read the Databricks watermark, pull only newer rows from PostgreSQL with
Spark JDBC, write Parquet with pyarrow (no Hadoop, works on Windows), upload it to a
Unity Catalog volume, then run one MERGE (or INSERT OVERWRITE for tables without a key)
straight from the files.
"""

from __future__ import annotations

import argparse
import importlib
import json
import os
import re
import shutil
import sys
import tempfile
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import closing, suppress
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from psycopg2 import sql

from utils.audit import (
    fail_stale_runs,
    finish_pipeline_run,
    log_dq_result,
    start_pipeline_run,
)
from utils.connection import get_databricks_connection, get_pg_connection, pg_jdbc
from utils.logger import get_logger
from utils.session import get_spark_session, pg_transaction, stop_spark

logger = get_logger("publish_marts")

SOURCE_SCHEMA = "marts"
_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

MART_CONFIG: dict[str, dict[str, Any]] = {
    "mart_monthly_transactions": {
        "key": [
            "month_start",
            "txn_type",
            "channel",
            "merchant_category",
            "txn_direction",
            "region",
            "state",
        ],
        "watermark": "month_start",
        "kind": "date",
    },
    "mart_kpi_monthly": {
        "key": ["month_start"],
        "watermark": "month_start",
        "kind": "date",
    },
    "mart_card_fraud": {
        "key": [
            "month_start",
            "card_type",
            "card_category",
            "card_tier",
            "merchant_category",
        ],
        "watermark": "month_start",
        "kind": "date",
    },
    "mart_support_performance": {
        "key": [
            "month_opened",
            "issue_type",
            "status",
            "customer_state",
            "income_band",
        ],
        "watermark": "month_opened",
        "kind": "date",
    },
    "mart_customer_360": {
        "key": ["customer_key"],
        "watermark": "mart_refreshed_at",
        "kind": "timestamp",
    },
    "mart_branch_performance": {
        "key": ["branch_key"],
        "watermark": "mart_refreshed_at",
        "kind": "timestamp",
    },
    "mart_loan_portfolio": {
        "key": ["loan_type", "status", "loan_amount_band", "term_band", "start_year"],
        "watermark": "mart_refreshed_at",
        "kind": "timestamp",
    },
}


@dataclass(frozen=True)
class MartPlan:
    table: str
    keys: list[str]
    watermark: str | None
    kind: str | None


def _ident(name: str) -> str:
    if not name or not _IDENT.match(name):
        raise ValueError(f"Unsafe or empty identifier: {name!r}")
    return name


def _dbx_name(*parts: str | None) -> str:
    return ".".join(f"`{_ident(p)}`" for p in parts if p)


def _dbx_type(dtype: Any) -> str:
    from pyspark.sql import types as T

    if isinstance(dtype, T.DecimalType):
        return f"DECIMAL({dtype.precision},{dtype.scale})"
    simple = {
        T.ByteType: "TINYINT",
        T.ShortType: "SMALLINT",
        T.IntegerType: "INT",
        T.LongType: "BIGINT",
        T.FloatType: "FLOAT",
        T.DoubleType: "DOUBLE",
        T.BooleanType: "BOOLEAN",
        T.StringType: "STRING",
        T.BinaryType: "BINARY",
        T.DateType: "DATE",
        T.TimestampType: "TIMESTAMP",
        T.TimestampNTZType: "TIMESTAMP_NTZ",
    }
    for spark_type, dbx_type in simple.items():
        if isinstance(dtype, spark_type):
            return dbx_type
    return "STRING"


def _sql_literal(value: Any, kind: str) -> str:
    if kind == "date":
        text = value.isoformat() if hasattr(value, "isoformat") else str(value)
        return f"DATE '{text[:10]}'"
    if isinstance(value, datetime):
        suffix = "+00:00" if value.tzinfo is None else ""
        return f"TIMESTAMPTZ '{value.isoformat(sep=' ')}{suffix}'"
    return f"TIMESTAMPTZ '{value}'"


def _primary_key(conn, table: str) -> list[str]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT kcu.column_name
            FROM information_schema.table_constraints AS tc
            JOIN information_schema.key_column_usage AS kcu
                ON tc.constraint_name = kcu.constraint_name
                AND tc.table_schema = kcu.table_schema
                AND tc.table_name = kcu.table_name
            WHERE tc.constraint_type = 'PRIMARY KEY'
                AND tc.table_schema = %s
                AND tc.table_name = %s
            ORDER BY kcu.ordinal_position
            """,
            (SOURCE_SCHEMA, table),
        )
        return [row[0] for row in cur.fetchall()]


def _discover(conn) -> dict[str, MartPlan]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT table_name
            FROM information_schema.tables
            WHERE table_schema = %s AND table_type = 'BASE TABLE'
            ORDER BY table_name
            """,
            (SOURCE_SCHEMA,),
        )
        names = [row[0] for row in cur.fetchall()]
    plans: dict[str, MartPlan] = {}
    for name in names:
        cfg = MART_CONFIG.get(name)
        if cfg:
            plans[name] = MartPlan(name, cfg["key"], cfg["watermark"], cfg["kind"])
            continue
        keys = _primary_key(conn, name)
        plans[name] = MartPlan(name, keys, None, None)
        logger.warning(
            "[%s] not in MART_CONFIG: full reload each run (%s). Add it for incremental loads.",
            name,
            "upsert on primary key" if keys else "insert overwrite, no key",
        )
    return plans


def _postgres_count(conn, table: str, where: str) -> int:
    query = sql.SQL("SELECT count(*) FROM {}.{}").format(
        sql.Identifier(SOURCE_SCHEMA), sql.Identifier(table)
    )
    if where:
        query = query + sql.SQL(" WHERE ") + sql.SQL(where)
    with conn.cursor() as cur:
        cur.execute(query)
        return int(cur.fetchone()[0])


def _where_clause(plan: MartPlan, last: Any, lookback: int) -> str:
    if last is None or plan.watermark is None:
        return ""
    column = _ident(plan.watermark)
    if plan.kind == "date":
        literal = _sql_literal(last, "date")
        if lookback > 0:
            return f"{column} >= ({literal} - INTERVAL '{int(lookback)} months')::date"
        return f"{column} >= {literal}"
    return f"{column} > {_sql_literal(last, 'timestamp')}"


def _read_mart(spark, table: str, where: str):
    j = pg_jdbc()
    source = f"{_ident(SOURCE_SCHEMA)}.{_ident(table)}"
    subquery = (
        f"(SELECT * FROM {source}" + (f" WHERE {where}" if where else "") + ") AS src"
    )
    return (
        spark.read.format("jdbc")
        .option("url", j["url"])
        .option("user", j["user"])
        .option("password", j["password"])
        .option("driver", j["driver"])
        .option("dbtable", subquery)
        .option("fetchsize", os.environ.get("PUBLISH_FETCH_SIZE", "10000"))
        .load()
    )


def _table_exists(cur, catalog: str, schema: str, table: str) -> bool:
    cur.execute(
        f"SELECT 1 FROM {_dbx_name(catalog, 'information_schema', 'tables')}"
        f" WHERE table_schema = '{_ident(schema)}' AND table_name = '{_ident(table)}'"
    )
    return cur.fetchone() is not None


def _last_watermark(cur, target: str, watermark: str) -> Any:
    cur.execute(f"SELECT max(`{_ident(watermark)}`) FROM {target}")
    row = cur.fetchone()
    return None if row is None or row[0] is None else row[0]


def _published_count(cur, target: str) -> int:
    cur.execute(f"SELECT count(*) FROM {target}")
    return int(cur.fetchone()[0])


def _column_ddl(df) -> str:
    return ", ".join(
        f"`{_ident(field.name)}` {_dbx_type(field.dataType)}"
        for field in df.schema.fields
    )


def _add_missing_columns(cur, catalog: str, schema: str, table: str, df) -> None:
    cur.execute(
        f"SELECT lower(column_name) FROM {_dbx_name(catalog, 'information_schema', 'columns')}"
        f" WHERE table_schema = '{_ident(schema)}' AND table_name = '{_ident(table)}'"
    )
    present = {row[0] for row in cur.fetchall()}
    missing = [f for f in df.schema.fields if f.name.lower() not in present]
    if not missing:
        return
    columns = ", ".join(f"`{_ident(f.name)}` {_dbx_type(f.dataType)}" for f in missing)
    cur.execute(
        f"ALTER TABLE {_dbx_name(catalog, schema, table)} ADD COLUMNS ({columns})"
    )
    logger.info("[%s] added columns: %s", table, [f.name for f in missing])


def _merge_sql(target: str, source: str, columns: list[str], keys: list[str]) -> str:
    on = " AND ".join(f"t.`{_ident(k)}` <=> s.`{_ident(k)}`" for k in keys)
    insert_cols = ", ".join(f"`{_ident(c)}`" for c in columns)
    insert_vals = ", ".join(f"s.`{_ident(c)}`" for c in columns)
    others = [c for c in columns if c not in keys]
    update = ""
    if others:
        sets = ", ".join(f"t.`{_ident(c)}` = s.`{_ident(c)}`" for c in others)
        update = f"WHEN MATCHED THEN UPDATE SET {sets} "
    return (
        f"MERGE INTO {target} AS t USING {source} AS s ON {on} "
        f"{update}WHEN NOT MATCHED THEN INSERT ({insert_cols}) VALUES ({insert_vals})"
    )


def _overwrite_sql(target: str, source: str, columns: list[str]) -> str:
    cols = ", ".join(f"`{_ident(c)}`" for c in columns)
    return f"INSERT OVERWRITE {target} ({cols}) SELECT {cols} FROM {source}"


def _affected_rows(cur, fallback: int) -> int:
    try:
        row = cur.fetchone()
    except Exception:  # noqa: BLE001 - metrics are optional
        return fallback
    return int(row[0]) if row and row[0] is not None else fallback


def _workspace_client():
    from databricks.sdk import WorkspaceClient

    host = os.environ.get("DATABRICKS_HOST") or os.environ.get(
        "DATABRICKS_SERVER_HOSTNAME"
    )
    token = os.environ.get("DATABRICKS_TOKEN") or os.environ.get(
        "DATABRICKS_ACCESS_TOKEN"
    )
    if host and not host.startswith("http"):
        host = f"https://{host}"
    return WorkspaceClient(host=host, token=token)


def _arrow_type(dtype: Any):
    import pyarrow as pa
    from pyspark.sql import types as T

    if isinstance(dtype, T.DecimalType):
        return pa.decimal128(dtype.precision, dtype.scale)
    if isinstance(dtype, T.TimestampType):
        return pa.timestamp("us", tz="UTC")
    if isinstance(dtype, T.TimestampNTZType):
        return pa.timestamp("us")
    simple = {
        T.ByteType: pa.int8(),
        T.ShortType: pa.int16(),
        T.IntegerType: pa.int32(),
        T.LongType: pa.int64(),
        T.FloatType: pa.float32(),
        T.DoubleType: pa.float64(),
        T.BooleanType: pa.bool_(),
        T.StringType: pa.string(),
        T.BinaryType: pa.binary(),
        T.DateType: pa.date32(),
    }
    for spark_type, arrow_type in simple.items():
        if isinstance(dtype, spark_type):
            return arrow_type
    return pa.string()


def _converter(dtype: Any):
    from pyspark.sql import types as T

    if isinstance(dtype, T.TimestampType):
        return lambda v: None if v is None else v.astimezone(UTC)
    if isinstance(dtype, T.BinaryType):
        return lambda v: None if v is None else bytes(v)
    known = (
        T.DecimalType,
        T.TimestampNTZType,
        T.ByteType,
        T.ShortType,
        T.IntegerType,
        T.LongType,
        T.FloatType,
        T.DoubleType,
        T.BooleanType,
        T.StringType,
        T.DateType,
    )
    if isinstance(dtype, known):
        return lambda v: v
    return lambda v: (
        None
        if v is None
        else json.dumps(v, default=str)
        if isinstance(v, (list, tuple, dict))
        else str(v)
    )


def _write_parquet(df, local_dir: Path, rows_per_file: int) -> list[Path]:
    import pyarrow as pa
    import pyarrow.parquet as pq

    fields = df.schema.fields
    schema = pa.schema([pa.field(f.name, _arrow_type(f.dataType)) for f in fields])
    converters = [_converter(f.dataType) for f in fields]
    chunk_rows = min(rows_per_file, 100_000)
    files: list[Path] = []
    writer = None
    in_file = 0

    def _flush(rows: list) -> None:
        nonlocal writer, in_file
        if not rows:
            return
        if writer is None:
            path = local_dir / f"part-{len(files):05d}.parquet"
            files.append(path)
            writer = pq.ParquetWriter(path, schema, compression="snappy")
            in_file = 0
        arrays = [
            pa.array([convert(row[i]) for row in rows], type=schema.field(i).type)
            for i, convert in enumerate(converters)
        ]
        writer.write_table(pa.Table.from_arrays(arrays, schema=schema))
        in_file += len(rows)
        if in_file >= rows_per_file:
            writer.close()
            writer = None

    try:
        rows: list = []
        for row in df.toLocalIterator():
            rows.append(row)
            if len(rows) >= chunk_rows:
                _flush(rows)
                rows = []
        _flush(rows)
    finally:
        if writer is not None:
            writer.close()
    return files


def _upload(client, files: list[Path], volume_dir: str, workers: int) -> None:
    def _put(path: Path) -> None:
        with path.open("rb") as handle:
            client.files.upload(f"{volume_dir}/{path.name}", handle, overwrite=True)

    with ThreadPoolExecutor(max_workers=max(1, min(workers, len(files)))) as pool:
        list(pool.map(_put, files))


def _clean_volume_dir(client, volume_dir: str, names: list[str]) -> None:
    for name in names:
        with suppress(Exception):
            client.files.delete(f"{volume_dir}/{name}")
    with suppress(Exception):
        client.files.delete_directory(volume_dir)


def publish_table(
    spark,
    plan: MartPlan,
    *,
    catalog: str,
    schema: str,
    volume: str,
    full: bool,
    lookback: int,
    rows_per_file: int,
    upload_workers: int,
) -> tuple[int, int, int]:
    """Publish one mart. Returns (source_rows, written_rows, table_rows)."""
    table = plan.table
    target = _dbx_name(catalog, schema, table)

    with (
        closing(get_pg_connection(f"publish_{table}")) as pg_conn,
        closing(get_databricks_connection()) as conn,
        conn.cursor() as cur,
    ):
        exists = _table_exists(cur, catalog, schema, table)
        # PG marts are fully refreshed (DROP + CTAS) every run, so publish mirrors
        # that with a full overwrite instead of an incremental MERGE on a watermark.
        where = ""
        expected = _postgres_count(pg_conn, table, where)
        logger.info("[%s] %s rows to publish (full overwrite)", table, expected)
        if expected == 0:
            return 0, 0, _published_count(cur, target) if exists else 0

        df = _read_mart(spark, table, where)
        columns = df.columns

        if exists:
            _add_missing_columns(cur, catalog, schema, table, df)
        else:
            cur.execute(
                f"CREATE TABLE IF NOT EXISTS {target} ({_column_ddl(df)}) USING DELTA"
            )

        volume_dir = (
            f"/Volumes/{_ident(catalog)}/{_ident(schema)}/{_ident(volume)}"
            f"/{_ident(table)}/{uuid.uuid4().hex[:12]}"
        )
        local_dir = Path(tempfile.mkdtemp(prefix=f"{table}_"))
        client = _workspace_client()
        names: list[str] = []
        try:
            files = _write_parquet(df, local_dir, rows_per_file)
            if not files:
                raise RuntimeError(f"[{table}] no rows were read from PostgreSQL")
            names = [f.name for f in files]
            _upload(client, files, volume_dir, upload_workers)
            logger.info("[%s] uploaded %d file(s)", table, len(files))

            source = f"(SELECT * FROM read_files('{volume_dir}/', format => 'parquet'))"
            statement = _overwrite_sql(target, source, columns)
            cur.execute(statement)
            written = _affected_rows(cur, expected)
        finally:
            shutil.rmtree(local_dir, ignore_errors=True)
            _clean_volume_dir(client, volume_dir, names)

        return expected, written, _published_count(cur, target)


def _preflight() -> None:
    missing = []
    for module, package in (
        ("databricks.sdk", "databricks-sdk"),
        ("pyarrow", "pyarrow"),
    ):
        try:
            importlib.import_module(module)
        except ImportError:
            missing.append(package)
    if missing:
        raise SystemExit(f"Missing packages, run: uv add {' '.join(missing)}")


def _log_failure(table: str, exc: BaseException) -> None:
    java = getattr(exc, "java_exception", None)
    detail = str(java.toString()) if java is not None else str(exc)
    first = (
        detail.strip().splitlines()[0][:300] if detail.strip() else type(exc).__name__
    )
    if java is not None:
        logger.error("[%s] publish failed (Spark): %s", table, first)
    else:
        logger.error("[%s] publish failed: %s", table, first, exc_info=exc)


def _record_outcome(
    pipeline_run_id: Any, results: dict[str, str], crashed: bool
) -> None:
    ok = sum(1 for status in results.values() if status == "SUCCESS")
    failed = len(results) - ok + (1 if crashed else 0)
    if not results and not crashed:
        return
    status = "SUCCESS" if failed == 0 else "FAILED" if ok == 0 else "PARTIAL"
    with pg_transaction() as conn, conn.cursor() as cur:
        cur.execute(
            """
            UPDATE audit.pipeline_runs
            SET status = %s,
                total_tables = %s,
                successful_tables = %s,
                failed_tables = %s
            WHERE pipeline_run_id = %s
            """,
            (status, len(results), ok, failed, pipeline_run_id),
        )
    logger.info(
        "Pipeline run %s recorded as %s (%d ok, %d failed)",
        pipeline_run_id,
        status,
        ok,
        failed,
    )


def _prepare_databricks(catalog: str, schema: str, volume: str) -> None:
    with closing(get_databricks_connection()) as conn, conn.cursor() as cur:
        cur.execute(f"CREATE SCHEMA IF NOT EXISTS {_dbx_name(catalog, schema)}")
        cur.execute(f"CREATE VOLUME IF NOT EXISTS {_dbx_name(catalog, schema, volume)}")


def _publish_all(
    spark,
    plans: list[MartPlan],
    pipeline_run_id: Any,
    parallel: int,
    catalog: str,
    schema: str,
    options: dict[str, Any],
) -> dict[str, str]:
    results: dict[str, str] = {}
    with ThreadPoolExecutor(max_workers=max(1, min(parallel, len(plans)))) as pool:
        futures = {
            pool.submit(
                publish_table,
                spark,
                plan,
                catalog=catalog,
                schema=schema,
                **options,
            ): plan.table
            for plan in plans
        }
        for future in as_completed(futures):
            table = futures[future]
            try:
                source_rows, written_rows, table_rows = future.result()
            except Exception as exc:  # noqa: BLE001 - preserve per-mart failures
                results[table] = "FAILED"
                _log_failure(table, exc)
                continue
            results[table] = "SUCCESS"
            log_dq_result(
                check_name="row_count_source_vs_published",
                status="PASSED" if source_rows == written_rows else "WARNING",
                records_checked=source_rows,
                records_failed=abs(source_rows - written_rows),
                details={"published_rows": written_rows, "table_rows": table_rows},
                pipeline_run_id=pipeline_run_id,
            )
            logger.info(
                "[%s] published %d rows (%d total in %s.%s)",
                table,
                written_rows,
                table_rows,
                catalog,
                schema,
            )
            if source_rows != written_rows:
                logger.warning(
                    "[%s] source=%d written=%d (did the mart change mid run?)",
                    table,
                    source_rows,
                    written_rows,
                )
    return results


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Incrementally publish PostgreSQL marts into the Databricks marts schema."
    )
    parser.add_argument("--tables", nargs="*", help="only these marts tables")
    parser.add_argument(
        "--full",
        action="store_true",
        help="ignore watermarks and republish every row (upserts in place)",
    )
    parser.add_argument(
        "--finalize",
        action="store_true",
        help="close the pipeline run when done (standalone runs always do)",
    )
    parser.add_argument(
        "--lookback",
        type=int,
        default=int(os.environ.get("PUBLISH_LOOKBACK_MONTHS", "0")),
        help="re-read this many extra months before the watermark on date marts",
    )
    parser.add_argument(
        "--parallel",
        type=int,
        default=int(os.environ.get("PUBLISH_TABLE_PARALLELISM", "4")),
        help="number of tables published at the same time",
    )
    parser.add_argument("--dag-id", default=os.environ.get("AIRFLOW_CTX_DAG_ID"))
    parser.add_argument(
        "--dag-run-id", default=os.environ.get("AIRFLOW_CTX_DAG_RUN_ID")
    )
    args = parser.parse_args(argv)
    if args.lookback < 0:
        parser.error("--lookback must be 0 or more")

    catalog = os.environ.get("DATABRICKS_CATALOG", "main")
    schema = os.environ.get("DATABRICKS_MARTS_SCHEMA", SOURCE_SCHEMA)
    options = {
        "volume": os.environ.get("PUBLISH_STAGE_VOLUME", "publish_stage"),
        "full": args.full,
        "lookback": args.lookback,
        "rows_per_file": int(os.environ.get("PUBLISH_ROWS_PER_FILE", "500000")),
        "upload_workers": int(os.environ.get("PUBLISH_UPLOAD_WORKERS", "4")),
    }

    _preflight()
    fail_stale_runs(max_age_hours=6)
    pipeline_run_id = start_pipeline_run(
        dag_id=args.dag_id,
        dag_run_id=args.dag_run_id,
        trigger_type="airflow" if args.dag_run_id else "manual",
    )

    results: dict[str, str] = {}
    crashed = False
    try:
        with closing(get_pg_connection("publish_marts")) as pg_conn:
            plans = list(_discover(pg_conn).values())
        if args.tables:
            wanted = set(args.tables)
            plans = [p for p in plans if p.table in wanted]
            missing = wanted - {p.table for p in plans}
            if missing:
                logger.warning("Not found in the marts schema: %s", sorted(missing))
        if not plans:
            logger.warning("Nothing to publish from the %s schema", SOURCE_SCHEMA)
        else:
            _prepare_databricks(catalog, schema, options["volume"])
            spark = get_spark_session("publish_marts", sources=("postgres",))
            results = _publish_all(
                spark, plans, pipeline_run_id, args.parallel, catalog, schema, options
            )
    except BaseException:
        crashed = True
        raise
    finally:
        stop_spark()
        if args.finalize or not args.dag_run_id:
            finish_pipeline_run(pipeline_run_id)
            _record_outcome(pipeline_run_id, results, crashed)

    logger.info("Done: %s", results)
    return 1 if "FAILED" in results.values() else 0


if __name__ == "__main__":
    sys.exit(main())
