"""Central session module — one import for Spark, PostgreSQL, MySQL and MongoDB access.

Design: NO cached/shared DB connections. Each `with` block opens its own
connection and commits / rolls back / closes it. That keeps audit writes
independent from data loads and avoids stale-connection and shared-transaction bugs.
Only the SparkSession is a per-process singleton.
"""

from __future__ import annotations

import os
from contextlib import contextmanager
from typing import Iterable, Iterator

from .connection import get_mongo_client, get_mysql_connection, get_pg_connection
from .engine import get_spark
from .logger import get_logger

logger = get_logger(__name__)

_spark = None


def get_spark_session(
    app_name: str = "banking-pipeline", sources: Iterable[str] = ("postgres",)
):
    """Process-wide SparkSession (see engine.get_spark for `sources`)."""
    global _spark
    if _spark is None:
        _spark = get_spark(app_name=app_name, sources=sources)
    return _spark


def stop_spark() -> None:
    global _spark
    if _spark is not None:
        _spark.stop()
        _spark = None
        logger.info("Spark session stopped")


@contextmanager
def pg_transaction(application_name: str = "banking-pipeline") -> Iterator:
    """Yield a PostgreSQL connection; commit on success, roll back on error, always close."""
    conn = get_pg_connection(application_name)
    try:
        yield conn
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


@contextmanager
def pg_cursor(dict_rows: bool = False) -> Iterator:
    """Convenience: one transaction, one cursor (cur.connection is the connection)."""
    import psycopg2.extras

    with pg_transaction() as conn:
        factory = psycopg2.extras.RealDictCursor if dict_rows else None
        with conn.cursor(cursor_factory=factory) as cur:
            yield cur


@contextmanager
def mysql_cursor() -> Iterator:
    """Yield a MySQL cursor on a fresh connection (closed afterwards)."""
    conn = get_mysql_connection()
    try:
        with conn.cursor() as cur:
            yield cur
    finally:
        conn.close()


@contextmanager
def mongo_database(db_name: str | None = None) -> Iterator:
    """Yield a pymongo Database on a fresh client (closed afterwards)."""
    from .config import require

    client = get_mongo_client()
    try:
        yield client[
            db_name or os.environ.get("MONGO_DB_NAME") or require("MONGO_DB_NAME")
        ]
    finally:
        client.close()
