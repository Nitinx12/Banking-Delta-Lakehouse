"""Spark readers/writers: MySQL & MongoDB  ->  PostgreSQL raw layer.

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
import uuid
from contextlib import closing
from typing import Optional

from psycopg2 import sql

from .connection import get_mongo_client, get_mysql_connection, mongo_settings, mysql_jdbc, pg_jdbc
from .logger import get_logger

logger = get_logger(__name__)

_MYSQL_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")
_PG_IDENT = re.compile(r"^[a-z_][a-z0-9_]*$")
_TS = re.compile(r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z?$")
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
    """'2024-05-01 10:00:00.123' / '...T...Z' -> 'YYYY-MM-DD HH:MM:SS[.ffffff]'."""
    if not _TS.match(value):
        raise ValueError(f"Bad timestamp watermark: {value!r}")
    return value.rstrip("Z").replace("T", " ")


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


# ------------------------------------------------------- batch window (source)
def mysql_max_watermark(cfg: dict) -> Optional[str]:
    """MAX(incremental_column) straight from MySQL, in MySQL's own format (index it!)."""
    col, schema, table = _ident(cfg["incremental_column"]), _ident(cfg["source_schema"]), _ident(cfg["source_table"])
    with closing(get_mysql_connection()) as conn, conn.cursor() as cur:
        cur.execute(f"SELECT MAX(`{col}`) FROM `{schema}`.`{table}`")
        (value,) = cur.fetchone()
    return None if value is None else str(value)


def mongo_max_watermark(cfg: dict) -> Optional[str]:
    """Highest value of incremental_column in the collection (needs an index on it)."""
    col = cfg["incremental_column"]
    with closing(get_mongo_client()) as client:
        doc = client[cfg["source_schema"]][cfg["source_table"]].find_one(
            {col: {"$ne": None}}, {col: 1}, sort=[(col, -1)]
        )
    if doc is None:
        return None
    value = doc[col]
    if hasattr(value, "isoformat"):  # datetime (pymongo returns naive UTC)
        return value.isoformat(sep=" ", timespec="microseconds")
    return str(value)


# ----------------------------------------------------------------------- MySQL
def _mysql_where(cfg: dict, start: Optional[str], end: Optional[str]) -> str:
    if cfg["load_strategy"] != "incremental" or end is None:
        return ""
    col, strat = _ident(cfg["incremental_column"]), cfg["watermark_strategy"]
    clauses = [f"`{col}` <= {_mysql_literal(strat, end)}"]
    if start is not None:
        clauses.append(f"`{col}` >= {_mysql_literal(strat, start)}")  # >= : boundary rows re-read; dedupe in staging layer
    return " WHERE " + " AND ".join(clauses)


def _mysql_bounds(schema: str, table: str, col: str, where: str) -> Optional[tuple[str, str]]:
    with closing(get_mysql_connection()) as conn, conn.cursor() as cur:
        cur.execute(f"SELECT MIN(`{col}`), MAX(`{col}`) FROM `{schema}`.`{table}`{where}")
        lo, hi = cur.fetchone()
    if lo is None or hi is None or lo == hi:
        return None
    return str(lo), str(hi)


def read_mysql(spark, cfg: dict, start: Optional[str] = None, end: Optional[str] = None):
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
    bounds = _mysql_bounds(schema, table, _ident(pcol), where) if pcol and nparts > 1 else None
    if bounds:
        reader = (
            reader.option("partitionColumn", pcol)
            .option("lowerBound", bounds[0])
            .option("upperBound", bounds[1])
            .option("numPartitions", str(nparts))
        )
        logger.info("[%s.%s] MySQL read: %d partitions on %s (%s .. %s)", schema, table, nparts, pcol, *bounds)
    else:
        logger.info("[%s.%s] MySQL read: single partition", schema, table)
    return reader.load()


# --------------------------------------------------------------------- MongoDB
def read_mongo(spark, cfg: dict, start: Optional[str] = None, end: Optional[str] = None):
    """Read a collection as (_id, doc-as-JSON). Schema drift can't break the raw layer."""
    from pyspark.sql import functions as F

    m = mongo_settings()
    reader = (
        spark.read.format("mongodb")
        .option("connection.uri", m["uri"])
        .option("database", cfg["source_schema"])
        .option("collection", cfg["source_table"])
        .option("outputExtendedJson", "true")  # BSON types Spark can't represent -> extended JSON, not an error
    )
    if cfg["load_strategy"] == "incremental" and end is not None:
        col, strat = cfg["incremental_column"], cfg["watermark_strategy"]
        cond = {"$lte": _mongo_value(strat, end)}
        if start is not None:
            cond["$gte"] = _mongo_value(strat, start)
        reader = reader.option("aggregation.pipeline", json.dumps([{"$match": {col: cond}}]))

    df = reader.load()
    others = [c for c in df.columns if c != "_id"]
    return df.select(
        F.col("_id").cast("string").alias("_id"),
        F.to_json(F.struct(*[F.col(f"`{c}`") for c in others])).alias("doc"),
    )


# -------------------------------------------------------------- audit columns
def add_audit_columns(df, table_run_id: uuid.UUID):
    from pyspark.sql import functions as F

    return df.withColumn("_batch_id", F.lit(str(table_run_id))).withColumn("_loaded_at", F.current_timestamp())


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
        df = df.coalesce(nparts)  # = number of parallel PG connections; do not overload the warehouse
    j = pg_jdbc()
    (
        df.write.format("jdbc")
        .option("url", j["url"])
        .option("user", j["user"])
        .option("password", j["password"])
        .option("driver", j["driver"])
        .option("dbtable", f"{schema}.{name}")
        .option("batchsize", str(cfg.get("batch_size") or 20000))
        .mode("overwrite")  # drops+recreates staging (types always match the current source)
        .save()
    )
    from .session import pg_cursor

    with pg_cursor() as cur:
        cur.execute(sql.SQL("SELECT count(*) FROM {}.{}").format(sql.Identifier(schema), sql.Identifier(name)))
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


def promote_staging(conn, cfg: dict, *, jsonb_columns: tuple[str, ...] = ()) -> int:
    """staging -> raw target, inside the CALLER's transaction. Returns rows inserted.

    * creates the target on first run, adds new source columns automatically (schema drift)
    * full load  -> TRUNCATE + INSERT (atomic: readers never see an empty table)
    * incremental -> append (raw is history; dedupe by business_key in the staging layer)
    * jsonb_columns: text columns to store as jsonb (e.g. ("doc",) for MongoDB)
    """
    t_schema, t_name = _pg_ident(cfg["target_schema"]), _pg_ident(cfg["target_table"])
    s_schema, s_name = staging_name(cfg)
    S, T = sql.Identifier(s_schema, s_name), sql.Identifier(t_schema, t_name)

    with conn.cursor() as cur:
        stg_cols = _columns(cur, s_schema, s_name)
        if not stg_cols:
            raise RuntimeError(f"Staging table {s_schema}.{s_name} not found or has no columns")

        if not _columns(cur, t_schema, t_name):
            cur.execute(sql.SQL("CREATE TABLE {} (LIKE {})").format(T, S))
            for col in jsonb_columns:
                cur.execute(sql.SQL("ALTER TABLE {} ALTER COLUMN {} TYPE jsonb USING {}::jsonb")
                            .format(T, sql.Identifier(col), sql.Identifier(col)))
        else:
            existing = {c for c, _ in _columns(cur, t_schema, t_name)}
            for col, coltype in stg_cols:
                if col not in existing:
                    logger.warning("Schema drift: adding column %s.%s.%s (%s)", t_schema, t_name, col, coltype)
                    ddl_type = "jsonb" if col in jsonb_columns else coltype
                    cur.execute(sql.SQL("ALTER TABLE {} ADD COLUMN {} " + ddl_type).format(T, sql.Identifier(col)))

        if cfg["load_strategy"] == "full":
            cur.execute(sql.SQL("TRUNCATE TABLE {}").format(T))

        cols = sql.SQL(", ").join(sql.Identifier(c) for c, _ in stg_cols)
        select = sql.SQL(", ").join(
            sql.SQL("{}::jsonb").format(sql.Identifier(c)) if c in jsonb_columns else sql.Identifier(c)
            for c, _ in stg_cols
        )
        cur.execute(sql.SQL("INSERT INTO {} ({}) SELECT {} FROM {}").format(T, cols, select, S))
        return cur.rowcount


def drop_staging(cfg: dict) -> None:
    from .session import pg_cursor

    schema, name = staging_name(cfg)
    with pg_cursor() as cur:
        cur.execute(sql.SQL("DROP TABLE IF EXISTS {}.{}").format(sql.Identifier(schema), sql.Identifier(name)))
