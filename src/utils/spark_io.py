"""Spark readers/writers: MySQL, MongoDB & Databricks  ->  PostgreSQL raw layer.

Load pattern (safe + fast)
--------------------------
1. snapshot the batch window:  start = last watermark,  end = MAX(incremental col) at the source
2. Spark reads ONLY that window, in parallel partitions
3. Spark writes to a STAGING table  raw._stg_<table>   (parallel multi-row INSERTs)
4. ONE Postgres transaction:  staging -> raw table  +  advance watermark   (atomic)
5. drop staging

If anything fails before step 4 commits, the raw table and the watermark are untouched,
so a retry simply re-extracts the same window. No duplicates, no gaps.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import uuid
from contextlib import closing
from datetime import timezone
from typing import TYPE_CHECKING, Optional

from psycopg2 import sql

if TYPE_CHECKING:
    from pyspark.sql import DataFrame

from .config import PROJECT_ROOT
from .connection import (
    dbx_call,
    get_databricks_connection,
    get_mongo_client,
    get_mysql_connection,
    mongo_settings,
    mysql_jdbc,
    pg_jdbc,
)
from .logger import get_logger

logger = get_logger(__name__)

_MYSQL_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")
_DBX_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_PG_IDENT = re.compile(r"^[a-z_][a-z0-9_]*$")
_TS = re.compile(
    r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$"
)
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_NUM = re.compile(r"^-?\d+(\.\d+)?$")
_OID = re.compile(r"^[0-9a-fA-F]{24}$")


# ------------------------------------------------------------------ validation
def _ident(name: str) -> str:
    """Identifiers come from audit.source_tables; still never trust them in SQL."""
    if not name or not _MYSQL_IDENT.match(name):
        raise ValueError(f"Unsafe or empty identifier: {name!r}")
    return name


def _pg_ident(name: str) -> str:
    if not _PG_IDENT.match(name or ""):
        raise ValueError(f"Postgres names must be lower_snake_case: {name!r}")
    return name


def _norm_ts(value: str) -> str:
    """'2024-05-01 10:00:00.123' / '...T...Z' -> 'YYYY-MM-DD HH:MM:SS[.ffffff]+00:00' (canonical UTC)."""
    if not _TS.match(value):
        raise ValueError(f"Bad timestamp watermark: {value!r}")
    # Ensure canonical UTC format with explicit +00:00 offset
    normalized = value.rstrip("Z").replace("T", " ")
    if not normalized.endswith("+00:00"):
        normalized = normalized + "+00:00"
    return normalized


def _mysql_literal(strategy: str, value: str) -> str:
    if strategy == "numeric":
        if not _NUM.match(value):
            raise ValueError(f"Bad numeric watermark: {value!r}")
        return value
    if strategy == "timestamp":
        return f"'{_norm_ts(value)}'"
    raise ValueError(f"MySQL does not support watermark_strategy={strategy!r}")


def _mongo_value(strategy: str, value: str):
    if strategy == "numeric":
        if not _NUM.match(value):
            raise ValueError(f"Bad numeric watermark: {value!r}")
        return float(value) if "." in value else int(value)
    if strategy == "timestamp":
        return {"$date": _norm_ts(value).replace(" ", "T") + "Z"}
    if strategy == "objectid":
        if not _OID.match(value):
            raise ValueError(f"Bad ObjectId watermark: {value!r}")
        return {"$oid": value}
    raise ValueError(f"Unknown watermark_strategy={strategy!r}")


def _dbx_ident(name: str) -> str:
    if not name or not _DBX_IDENT.match(name):
        raise ValueError(f"Unsafe or empty Databricks identifier: {name!r}")
    return name


def _dbx_qualified(cfg: dict) -> str:
    """`catalog`.`schema`.`table` — catalog from the config or DATABRICKS_CATALOG."""
    parts = [p for p in cfg["source_schema"].split(".") if p]
    parts.append(cfg["source_table"])
    if len(parts) == 2 and os.environ.get("DATABRICKS_CATALOG"):
        parts.insert(0, os.environ["DATABRICKS_CATALOG"])
    return ".".join(f"`{_dbx_ident(p)}`" for p in parts)


def _dbx_literal(strategy: str, value: str) -> str:
    if strategy == "numeric":
        if not _NUM.match(value):
            raise ValueError(f"Bad numeric watermark: {value!r}")
        return value
    if strategy == "timestamp":
        if _DATE.match(value):  # date-only watermark value
            return f"TIMESTAMP'{value}'"
        return f"TIMESTAMP'{_norm_ts(value)}'"
    raise ValueError(f"Databricks does not support watermark_strategy={strategy!r}")


# ------------------------------------------------------- batch window (source)
def mysql_max_watermark(cfg: dict) -> Optional[str]:
    """MAX(incremental_column) straight from MySQL, in MySQL's own format (index it!).

    Returns canonical UTC timestamp string with +00:00 offset for timestamp columns.
    """
    col, schema, table = (
        _ident(cfg["incremental_column"]),
        _ident(cfg["source_schema"]),
        _ident(cfg["source_table"]),
    )
    with closing(get_mysql_connection()) as conn, conn.cursor() as cur:
        cur.execute(f"SELECT MAX(`{col}`) FROM `{schema}`.`{table}`")
        (value,) = cur.fetchone()
    if value is None:
        return None
    if hasattr(value, "isoformat"):  # datetime
        return value.isoformat(sep=" ", timespec="microseconds") + "+00:00"
    return str(value)


def mongo_max_watermark(cfg: dict) -> Optional[str]:
    """Highest value of incremental_column in the collection (needs an index on it).

    Returns canonical UTC timestamp string with +00:00 offset.
    """
    col = cfg["incremental_column"]
    with closing(get_mongo_client()) as client:
        doc = client[cfg["source_schema"]][cfg["source_table"]].find_one(
            {col: {"$ne": None}}, {col: 1}, sort=[(col, -1)]
        )
    if doc is None:
        return None
    value = doc[col]
    if hasattr(value, "isoformat"):  # datetime (pymongo returns naive UTC)
        # pymongo returns naive UTC; make it explicit
        return value.isoformat(sep=" ", timespec="microseconds") + "+00:00"
    return str(value)


def databricks_max_watermark(cfg: dict) -> Optional[str]:
    """MAX(incremental_column) straight from Databricks, in a normalised text form.

    Returns canonical UTC timestamp string with +00:00 offset.
    """
    col = _dbx_ident(cfg["incremental_column"])
    label = f"{cfg['source_schema']}.{cfg['source_table']}"

    def query() -> object:
        with closing(get_databricks_connection()) as conn, conn.cursor() as cur:
            cur.execute(f"SELECT MAX(`{col}`) FROM {_dbx_qualified(cfg)}")
            (value,) = cur.fetchone()
        return value

    value = dbx_call(label, query)
    if value is None:
        return None
    if hasattr(value, "isoformat"):  # date / datetime
        if not hasattr(value, "hour"):  # date column
            return value.isoformat()
        if value.tzinfo is not None:  # watermark text is naive UTC (see _norm_ts)
            value = value.astimezone(timezone.utc).replace(tzinfo=None)
        return value.isoformat(sep=" ", timespec="microseconds") + "+00:00"
    return str(value)


# ----------------------------------------------------------------------- MySQL
def _mysql_where(cfg: dict, start: Optional[str], end: Optional[str]) -> str:
    if cfg["load_strategy"] != "incremental" or end is None:
        return ""
    col, strat = _ident(cfg["incremental_column"]), cfg["watermark_strategy"]
    clauses = [f"`{col}` <= {_mysql_literal(strat, end)}"]
    if start is not None:
        clauses.append(
            f"`{col}` >= {_mysql_literal(strat, start)}"
        )  # >= : boundary rows re-read; dedupe in staging layer
    return " WHERE " + " AND ".join(clauses)


def _mysql_bounds(
    schema: str, table: str, col: str, where: str
) -> Optional[tuple[str, str]]:
    with closing(get_mysql_connection()) as conn, conn.cursor() as cur:
        cur.execute(
            f"SELECT MIN(`{col}`), MAX(`{col}`) FROM `{schema}`.`{table}`{where}"
        )
        lo, hi = cur.fetchone()
    if lo is None or hi is None or lo == hi:
        return None
    return str(lo), str(hi)


def mysql_count(
    cfg: dict, start: Optional[str] = None, end: Optional[str] = None
) -> int:
    """Exact number of source rows in the batch window (for the row-count DQ check)."""
    schema, table = _ident(cfg["source_schema"]), _ident(cfg["source_table"])
    where = _mysql_where(cfg, start, end)
    with closing(get_mysql_connection()) as conn, conn.cursor() as cur:
        cur.execute(f"SELECT COUNT(*) FROM `{schema}`.`{table}`{where}")
        (count,) = cur.fetchone()
    return int(count)


_MYSQL_TYPE_MAP = {
    "tinyint": "smallint",
    "smallint": "smallint",
    "mediumint": "integer",
    "int": "integer",
    "integer": "integer",
    "bigint": "bigint",
    "float": "real",
    "double": "double precision",
    "date": "date",
    "time": "time",
    "year": "smallint",
    "json": "jsonb",
    "tinytext": "text",
    "text": "text",
    "mediumtext": "text",
    "longtext": "text",
    "enum": "text",
    "set": "text",
    "tinyblob": "bytea",
    "blob": "bytea",
    "mediumblob": "bytea",
    "longblob": "bytea",
    "binary": "bytea",
    "varbinary": "bytea",
}
_MYSQL_UNSIGNED = {
    "tinyint": "smallint",
    "smallint": "integer",
    "mediumint": "integer",
    "int": "bigint",
    "integer": "bigint",
    "bigint": "numeric(20,0)",
}


def _mysql_pg_type(
    data_type, column_type, char_len, num_precision, num_scale, dt_precision
) -> str:
    """Map one MySQL column to its exact PostgreSQL type equivalent."""
    dt = (data_type or "").lower()
    unsigned = "unsigned" in (column_type or "").lower()
    if dt in ("decimal", "numeric"):
        return f"numeric({num_precision or 10},{num_scale or 0})"
    if dt in ("datetime", "timestamp"):
        base = "timestamp" if dt == "datetime" else "timestamptz"
        return f"{base}({dt_precision})" if dt_precision is not None else base
    if dt == "char":
        return f"char({char_len or 1})"
    if dt == "varchar":
        return f"varchar({char_len})" if char_len else "text"
    if dt == "bit":
        return f"bit({num_precision})" if num_precision else "bit"
    if unsigned and dt in _MYSQL_UNSIGNED:
        return _MYSQL_UNSIGNED[dt]
    return _MYSQL_TYPE_MAP.get(dt, "text")


def mysql_column_types(cfg: dict) -> dict[str, str]:
    """Exact PostgreSQL type per column, read from MySQL's own information_schema."""
    schema, table = _ident(cfg["source_schema"]), _ident(cfg["source_table"])
    with closing(get_mysql_connection()) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, CHARACTER_MAXIMUM_LENGTH,
                   NUMERIC_PRECISION, NUMERIC_SCALE, DATETIME_PRECISION
            FROM information_schema.columns
            WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s
            ORDER BY ORDINAL_POSITION
            """,
            (schema, table),
        )
        rows = cur.fetchall()
    return {
        name: _mysql_pg_type(dtype, ctype, char_len, prec, scale, dtp)
        for name, dtype, ctype, char_len, prec, scale, dtp in rows
    }


def read_mysql(
    spark, cfg: dict, start: Optional[str] = None, end: Optional[str] = None
):
    """Read one MySQL table (or incremental window) with parallel, streamed JDBC partitions."""
    schema, table = _ident(cfg["source_schema"]), _ident(cfg["source_table"])
    where = _mysql_where(cfg, start, end)
    j = mysql_jdbc()

    reader = (
        spark.read.format("jdbc")
        .option("url", j["url"])
        .option("user", j["user"])
        .option("password", j["password"])
        .option("driver", j["driver"])
        .option("dbtable", f"(SELECT * FROM `{schema}`.`{table}`{where}) AS src")
        .option("fetchsize", str(cfg.get("fetch_size") or 10000))
    )

    pcol, nparts = cfg.get("partition_column"), int(cfg.get("num_partitions") or 1)
    bounds = (
        _mysql_bounds(schema, table, _ident(pcol), where)
        if pcol and nparts > 1
        else None
    )
    if bounds:
        reader = (
            reader.option("partitionColumn", pcol)
            .option("lowerBound", bounds[0])
            .option("upperBound", bounds[1])
            .option("numPartitions", str(nparts))
        )
        logger.info(
            "[%s.%s] MySQL read: %d partitions on %s (%s .. %s)",
            schema,
            table,
            nparts,
            pcol,
            *bounds,
        )
    else:
        logger.info("[%s.%s] MySQL read: single partition", schema, table)
    return reader.load()


# --------------------------------------------------------------------- MongoDB
def _mongo_window(cfg: dict, start: Optional[str], end: Optional[str]) -> dict:
    """Extended-JSON $match filter for the batch window ({} = whole collection)."""
    if cfg["load_strategy"] != "incremental" or end is None:
        return {}
    col, strat = cfg["incremental_column"], cfg["watermark_strategy"]
    cond = {"$lte": _mongo_value(strat, end)}
    if start is not None:
        cond["$gte"] = _mongo_value(
            strat, start
        )  # >= : boundary rows re-read; dedupe in staging layer
    return {col: cond}


def mongo_count(
    cfg: dict, start: Optional[str] = None, end: Optional[str] = None
) -> int:
    """Exact number of source documents in the batch window (for the row-count DQ check)."""
    from bson import json_util

    flt = json_util.loads(json.dumps(_mongo_window(cfg, start, end)))
    with closing(get_mongo_client()) as client:
        return client[cfg["source_schema"]][cfg["source_table"]].count_documents(flt)


def read_mongo(
    spark, cfg: dict, start: Optional[str] = None, end: Optional[str] = None
):
    """Read a collection with its fields as columns (same names, inferred types).

    Schema is inferred from a sample of MONGO_SAMPLE_SIZE documents (default 10000).
    A field that never appears in the sample would be missing -> raise the sample size
    for very irregular collections.
    """
    m = mongo_settings()
    reader = (
        spark.read.format("mongodb")
        .option("connection.uri", m["uri"])
        .option("database", cfg["source_schema"])
        .option("collection", cfg["source_table"])
        .option("sampleSize", os.environ.get("MONGO_SAMPLE_SIZE", "10000"))
        .option(
            "outputExtendedJson", "true"
        )  # BSON types Spark can't represent -> extended JSON, not an error
    )
    window = _mongo_window(cfg, start, end)
    if window:
        reader = reader.option("aggregation.pipeline", json.dumps([{"$match": window}]))
    return reader.load()


_MONGO_DATE_NAME = re.compile(r"_date$|^(?:dob|date_of_birth)$", re.IGNORECASE)
_MONGO_TS_NAME = re.compile(r"_(?:at|ts|timestamp|dt)$", re.IGNORECASE)


def _temporal_expr(name: str, kind: str):
    from pyspark.sql import functions as F

    column = F.col(f"`{name}`")
    return F.to_date(column) if kind == "date" else F.to_timestamp(column)


def cast_temporal(df: DataFrame) -> tuple[DataFrame, dict[str, str]]:
    """Cast ISO date/timestamp TEXT fields to real temporal types (Mongo is schemaless).

    Mongo holds these as strings, so Spark infers text; the raw contract wants
    date/timestamp. Only StringType fields whose NAME looks like a date are cast, so
    genuine free-text columns are untouched. Returns (df, {column: "date"|"timestamp"}).
    """
    from pyspark.sql import functions as F
    from pyspark.sql import types as T

    cols, casts = [], {}
    for f in df.schema.fields:
        kind = None
        if isinstance(f.dataType, T.StringType):
            if _MONGO_DATE_NAME.search(f.name):
                kind = "date"
            elif _MONGO_TS_NAME.search(f.name):
                kind = "timestamp"
        if kind:
            cols.append(_temporal_expr(f.name, kind).alias(f.name))
            casts[f.name] = kind
        else:
            cols.append(F.col(f"`{f.name}`").alias(f.name))
    return df.select(*cols), casts


def temporal_parse_failures(df: DataFrame, casts: dict[str, str]) -> dict[str, int]:
    """Count values that are present but unparseable (they become NULL after the cast)."""
    from pyspark.sql import functions as F

    if not casts:
        return {}
    exprs = [
        F.sum(
            F.when(
                F.col(f"`{name}`").isNotNull() & _temporal_expr(name, kind).isNull(), 1
            ).otherwise(0)
        ).alias(name)
        for name, kind in casts.items()
    ]
    row = df.agg(*exprs).first()
    return {name: int(row[name] or 0) for name in casts}


def cast_integers(df: DataFrame, columns: tuple[str, ...]) -> DataFrame:
    """Cast named TEXT columns to bigint (Mongo holds numeric keys as strings)."""
    from pyspark.sql import functions as F

    wanted = set(columns)
    if not wanted:
        return df
    return df.select(
        *(
            F.col(f"`{f.name}`").cast("bigint").alias(f.name)
            if f.name in wanted
            else F.col(f"`{f.name}`").alias(f.name)
            for f in df.schema.fields
        )
    )


# ----------------------------------------------------------------- Databricks
def _dbx_where(cfg: dict, start: Optional[str], end: Optional[str]) -> str:
    if cfg["load_strategy"] != "incremental" or end is None:
        return ""
    col, strat = _dbx_ident(cfg["incremental_column"]), cfg["watermark_strategy"]
    clauses = [f"`{col}` <= {_dbx_literal(strat, end)}"]
    if start is not None:
        # Use >= with a small look-back overlap to avoid losing rows that share
        # the watermark timestamp. The staging layer dedupes by business key.
        # Look-back window defaults to 1 minute (configurable via DATABRICKS_LOOKBACK_MINUTES).
        lookback_minutes = int(os.environ.get("DATABRICKS_LOOKBACK_MINUTES", "1"))
        from datetime import datetime, timedelta

        try:
            # Parse the start watermark and subtract lookback
            start_dt = datetime.fromisoformat(
                start.replace("Z", "+00:00").replace(" ", "T")
            )
            if start_dt.tzinfo is None:
                start_dt = start_dt.replace(tzinfo=timezone.utc)
            lookback_start = start_dt - timedelta(minutes=lookback_minutes)
            lookback_str = lookback_str = (
                lookback_start.strftime("%Y-%m-%d %H:%M:%S") + "+00:00"
            )
            clauses.append(f"`{col}` >= {_dbx_literal(strat, lookback_str)}")
        except (ValueError, AttributeError):
            # Fallback to strict > if parsing fails
            clauses.append(f"`{col}` > {_dbx_literal(strat, start)}")
    return " WHERE " + " AND ".join(clauses)


def _dbx_columns(cfg: dict) -> list[tuple[str, str]]:
    """(column_name, data_type) from DESCRIBE, stopping before the partition section."""
    label = f"{cfg['source_schema']}.{cfg['source_table']}"

    def describe() -> list[tuple[str, str]]:
        with closing(get_databricks_connection()) as conn, conn.cursor() as cur:
            cur.execute(f"DESCRIBE TABLE {_dbx_qualified(cfg)}")
            columns = []
            for name, dtype, *_ in cur.fetchall():
                if not name or name.startswith("#") or name == "col_name":
                    break
                columns.append((_dbx_ident(name), dtype))
        return columns

    return dbx_call(label, describe)


def databricks_count(
    cfg: dict, start: Optional[str] = None, end: Optional[str] = None
) -> int:
    """Exact number of source rows in the batch window (for the row-count DQ check)."""
    where = _dbx_where(cfg, start, end)
    label = f"{cfg['source_schema']}.{cfg['source_table']}"

    def count() -> int:
        with closing(get_databricks_connection()) as conn, conn.cursor() as cur:
            cur.execute(f"SELECT COUNT(*) FROM {_dbx_qualified(cfg)}{where}")
            return int(cur.fetchone()[0])

    return dbx_call(label, count)


def read_databricks(
    spark, cfg: dict, start: Optional[str] = None, end: Optional[str] = None
):
    """Read a Databricks table (or incremental window) into a Spark DataFrame.

    The SQL warehouse is queried with the pure-Python connector; results arrive as
    Arrow and are streamed to a local Parquet file, which Spark then reads. That
    keeps memory flat for large tables and needs no JDBC driver on the classpath.
    """
    import pyarrow as pa
    import pyarrow.parquet as pq

    columns = _dbx_columns(cfg)
    if not columns:
        raise RuntimeError(f"Cannot introspect Databricks table {_dbx_qualified(cfg)}")
    col_list = ", ".join(f"`{name}`" for name, _ in columns)
    query = f"SELECT {col_list} FROM {_dbx_qualified(cfg)}{_dbx_where(cfg, start, end)}"

    batch_rows = int(os.environ.get("DATABRICKS_FETCH_ROWS", "200000"))
    out_dir = PROJECT_ROOT / ".spark" / "tmp" / f"databricks_{cfg['target_table']}"
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / "part-0.parquet"

    schema = pa.schema(
        [pa.field(name, _dbx_arrow_type(dtype)) for name, dtype in columns]
    )

    def fetch() -> int:
        writer: Optional[pq.ParquetWriter] = None
        rows = 0
        try:
            with closing(get_databricks_connection()) as conn, conn.cursor() as cur:
                cur.execute(query)
                while True:
                    batch = cur.fetchmany_arrow(batch_rows)
                    if batch.num_rows == 0:
                        break
                    if writer is None:
                        writer = pq.ParquetWriter(out_file, batch.schema)
                    writer.write_table(batch)
                    rows += batch.num_rows
        finally:
            if writer is not None:
                writer.close()  # a retried attempt reopens the file, truncating it
        return rows

    total = dbx_call(cfg["source_table"], fetch)

    if total == 0:  # empty result: still write an empty file so Spark sees the schema
        pq.write_table(pa.Table.from_batches([], schema=schema), out_file)

    logger.info("[%s] Databricks read: %d rows", cfg["source_table"], total)
    return spark.read.parquet(
        str(out_file)
    )  # single file: avoids Hadoop dir-listing on Windows


def _dbx_arrow_type(sql_type: str):
    """Map a Databricks SQL type to a pyarrow type (used for empty results)."""
    import pyarrow as pa

    base = sql_type.lower().split("(")[0].strip()
    mapping = {
        "bigint": pa.int64(),
        "int": pa.int32(),
        "integer": pa.int32(),
        "smallint": pa.int16(),
        "tinyint": pa.int8(),
        "double": pa.float64(),
        "float": pa.float32(),
        "real": pa.float32(),
        "boolean": pa.bool_(),
        "date": pa.date32(),
        "timestamp": pa.timestamp("us", tz="UTC"),
        "timestamp_ntz": pa.timestamp("us"),
        "string": pa.string(),
        "varchar": pa.string(),
        "char": pa.string(),
        "binary": pa.binary(),
    }
    if base == "decimal":
        precision, scale = (sql_type.split("(")[1].rstrip(")").split(",") + ["0"])[:2]
        return pa.decimal128(int(precision), int(scale))
    return mapping.get(base, pa.string())


def prepare_for_jdbc(df):
    """Make a Mongo DataFrame writable through JDBC WITHOUT renaming or retyping columns.

    Spark JDBC cannot write struct / map / array-of-struct / all-null columns, so those become:
      * struct, map, array-of-struct/array  -> JSON text (landed as jsonb in Postgres)
      * all-null (NullType)                 -> string
    Everything else (string, int, bigint, double, decimal, bool, timestamp, binary,
    arrays of primitives) is written as-is. Returns (df, names_of_json_columns).
    """
    from pyspark.sql import functions as F
    from pyspark.sql import types as T

    def atomic(dt) -> bool:
        return not isinstance(dt, (T.StructType, T.MapType, T.ArrayType, T.NullType))

    cols, json_cols = [], []
    for f in df.schema.fields:
        c, dt = F.col(f"`{f.name}`"), f.dataType
        if f.name == "_id":
            if isinstance(dt, T.StructType) and "oid" in dt.names:
                c = F.col("`_id`.oid").cast(
                    "string"
                )  # legacy connector shape {oid: ...}
            elif isinstance(dt, T.StringType):
                # outputExtendedJson leaves ObjectId as {"$oid": "hex"}; plain string _ids pass through
                c = F.coalesce(F.get_json_object(c, "$['$oid']"), c)
        elif isinstance(dt, T.NullType):
            c = c.cast("string")
        elif isinstance(dt, (T.StructType, T.MapType)) or (
            isinstance(dt, T.ArrayType) and not atomic(dt.elementType)
        ):
            c = F.to_json(c)
            json_cols.append(f.name)
        cols.append(c.alias(f.name))
    return df.select(*cols), tuple(json_cols)


# -------------------------------------------------------------- audit columns
def add_audit_columns(df, table_run_id: uuid.UUID):
    from pyspark.sql import functions as F

    return df.withColumn("_batch_id", F.lit(str(table_run_id))).withColumn(
        "_loaded_at", F.current_timestamp()
    )


# ---------------------------------------------------------- write to Postgres
def staging_name(cfg: dict) -> tuple[str, str]:
    schema, table = _pg_ident(cfg["target_schema"]), _pg_ident(cfg["target_table"])
    return schema, f"_stg_{table}"[:63]


def write_staging(df, cfg: dict) -> int:
    """Spark -> raw._stg_<table> (dropped & recreated each run). Returns rows written.

    No df.count() before the write (that would read the source twice);
    the row count comes from the staging table afterwards.
    """
    schema, name = staging_name(cfg)
    nparts = max(1, int(cfg.get("num_partitions") or 4))
    if df.rdd.getNumPartitions() > nparts:
        df = df.coalesce(
            nparts
        )  # = number of parallel PG connections; do not overload the warehouse
    j = pg_jdbc()
    (
        df.write.format("jdbc")
        .option("url", j["url"])
        .option("user", j["user"])
        .option("password", j["password"])
        .option("driver", j["driver"])
        .option("dbtable", f"{schema}.{name}")
        .option("batchsize", str(cfg.get("batch_size") or 20000))
        .mode(
            "overwrite"
        )  # drops+recreates staging (types always match the current source)
        .save()
    )
    from .session import pg_cursor

    with pg_cursor() as cur:
        cur.execute(
            sql.SQL("SELECT count(*) FROM {}.{}").format(
                sql.Identifier(schema), sql.Identifier(name)
            )
        )
        return cur.fetchone()[0]


def _columns(cur, schema: str, table: str) -> list[tuple[str, str]]:
    cur.execute(
        """
        SELECT a.attname, format_type(a.atttypid, a.atttypmod)
        FROM pg_attribute a
        WHERE a.attrelid = to_regclass(%s) AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
        """,
        (f"{schema}.{table}",),
    )
    return cur.fetchall()


def promote_staging(
    conn,
    cfg: dict,
    *,
    jsonb_columns: tuple[str, ...] = (),
    column_types: Optional[dict[str, str]] = None,
) -> int:
    """staging -> raw target, inside the CALLER's transaction. Returns rows inserted.

    * creates the target on first run, adds new source columns automatically (schema drift)
    * full load  -> TRUNCATE + INSERT (atomic: readers never see an empty table)
    * incremental -> append (raw is history; dedupe by business_key in the staging layer)
    * jsonb_columns: text columns to create as jsonb (existing jsonb target columns are cast automatically)
    * column_types: exact Postgres types to use when creating the target (e.g. MySQL varchar(n))
    * metadata contract on create: _batch_id/_loaded_at NOT NULL, _loaded_at is timestamptz
    """
    t_schema, t_name = _pg_ident(cfg["target_schema"]), _pg_ident(cfg["target_table"])
    s_schema, s_name = staging_name(cfg)
    S, T = sql.Identifier(s_schema, s_name), sql.Identifier(t_schema, t_name)

    with conn.cursor() as cur:
        stg_cols = _columns(cur, s_schema, s_name)
        if not stg_cols:
            raise RuntimeError(
                f"Staging table {s_schema}.{s_name} not found or has no columns"
            )

        if not _columns(cur, t_schema, t_name):
            cur.execute(sql.SQL("CREATE TABLE {} (LIKE {})").format(T, S))
            for col, coltype in (column_types or {}).items():
                if coltype.lower().startswith("timestamptz"):
                    using = sql.SQL("{} AT TIME ZONE 'UTC'").format(sql.Identifier(col))
                else:
                    using = sql.SQL("{}::{}").format(
                        sql.Identifier(col), sql.SQL(coltype)
                    )
                cur.execute(
                    sql.SQL("ALTER TABLE {} ALTER COLUMN {} TYPE {} USING {}").format(
                        T, sql.Identifier(col), sql.SQL(coltype), using
                    )
                )
            for col in jsonb_columns:
                cur.execute(
                    sql.SQL(
                        "ALTER TABLE {} ALTER COLUMN {} TYPE jsonb USING {}::jsonb"
                    ).format(T, sql.Identifier(col), sql.Identifier(col))
                )
            # raw contract: metadata columns are NOT NULL; _loaded_at is timezone-aware
            # (Spark has no zoned type, so the column is fixed here, not inferred)
            stg_names = {c for c, _ in stg_cols}
            if "_loaded_at" in stg_names:
                cur.execute(
                    sql.SQL(
                        "ALTER TABLE {} ALTER COLUMN {} TYPE timestamptz "
                        "USING {} AT TIME ZONE 'UTC'"
                    ).format(
                        T, sql.Identifier("_loaded_at"), sql.Identifier("_loaded_at")
                    )
                )
            for meta_col in ("_batch_id", "_loaded_at"):
                if meta_col in stg_names:
                    cur.execute(
                        sql.SQL("ALTER TABLE {} ALTER COLUMN {} SET NOT NULL").format(
                            T, sql.Identifier(meta_col)
                        )
                    )
        else:
            existing = {c for c, _ in _columns(cur, t_schema, t_name)}
            for col, coltype in stg_cols:
                if col not in existing:
                    wanted = (
                        "jsonb"
                        if col in jsonb_columns
                        else ((column_types or {}).get(col) or coltype)
                    )
                    logger.warning(
                        "Schema drift: adding column %s.%s.%s (%s)",
                        t_schema,
                        t_name,
                        col,
                        wanted,
                    )
                    cur.execute(
                        sql.SQL("ALTER TABLE {} ADD COLUMN {} {}").format(
                            T, sql.Identifier(col), sql.SQL(wanted)
                        )
                    )

        if cfg["load_strategy"] == "full":
            cur.execute(sql.SQL("TRUNCATE TABLE {}").format(T))

        target_types = dict(_columns(cur, t_schema, t_name))
        as_jsonb = {
            c
            for c, _ in stg_cols
            if c in jsonb_columns or target_types.get(c) == "jsonb"
        }
        cols = sql.SQL(", ").join(sql.Identifier(c) for c, _ in stg_cols)
        select = sql.SQL(", ").join(
            sql.SQL("{}::jsonb").format(sql.Identifier(c))
            if c in as_jsonb
            else sql.Identifier(c)
            for c, _ in stg_cols
        )

        if cfg["load_strategy"] == "incremental" and cfg.get("business_key"):
            business_key = _pg_ident(cfg["business_key"])
            incremental_col = _pg_ident(cfg["incremental_column"])
            cur.execute(
                sql.SQL("""
                    INSERT INTO {target} ({cols})
                    SELECT {select}
                    FROM (
                        SELECT {select},
                               ROW_NUMBER() OVER (PARTITION BY {business_key} ORDER BY {incremental_col} DESC) AS rn
                        FROM {staging}
                    ) s
                    WHERE s.rn = 1
                """).format(
                    target=T,
                    cols=cols,
                    select=select,
                    business_key=sql.Identifier(business_key),
                    incremental_col=sql.Identifier(incremental_col),
                    staging=S,
                )
            )
        else:
            cur.execute(
                sql.SQL("INSERT INTO {} ({}) SELECT {} FROM {}").format(
                    T, cols, select, S
                )
            )
        return cur.rowcount


def drop_staging(cfg: dict) -> None:
    from .session import pg_cursor

    schema, name = staging_name(cfg)
    with pg_cursor() as cur:
        cur.execute(
            sql.SQL("DROP TABLE IF EXISTS {}.{}").format(
                sql.Identifier(schema), sql.Identifier(name)
            )
        )
