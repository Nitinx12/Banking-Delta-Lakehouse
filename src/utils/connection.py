"""Connection factories + JDBC/Mongo settings for all systems.

Driver imports are lazy, so a MySQL script does not need pymongo installed
(and vice-versa). Credentials come only from environment variables.
"""

from __future__ import annotations

import os
import time
from typing import Callable, TypeVar

from . import config  # noqa: F401  (loads .env)
from .config import require
from .logger import get_logger

logger = get_logger(__name__)

T = TypeVar("T")

# --------------------------------------------------------------------------
# Plain Python connections (audit writes, bounds queries, MAX() watermark ...)
# --------------------------------------------------------------------------


def get_pg_connection(application_name: str = "banking-pipeline"):
    """PostgreSQL warehouse connection (banking_delta). Caller owns commit/close.

    Session timezone is forced to UTC so all TIMESTAMPTZ operations
    are consistent regardless of server configuration. A lock timeout turns a
    wait on another session's lock into a fast, readable error instead of a hang.
    """
    import psycopg2

    conn = psycopg2.connect(
        host=require("PG_HOST"),
        port=int(os.environ.get("PG_PORT", 5432)),
        dbname=require("PG_DB"),
        user=require("PG_USER"),
        password=os.environ.get("PG_PASS", ""),
        connect_timeout=int(os.environ.get("PG_CONNECT_TIMEOUT", 10)),
        application_name=application_name,
        options=f"-c timezone=UTC -c lock_timeout={os.environ.get('PG_LOCK_TIMEOUT', '60s')}",
    )
    return conn


def get_mysql_connection():
    """MySQL source connection (read-mostly). Caller owns close.

    Session timezone is forced to UTC so datetime operations
    are consistent regardless of server configuration.
    """
    import pymysql

    conn = pymysql.connect(
        host=require("MYSQL_HOST"),
        port=int(os.environ.get("MYSQL_PORT", 3306)),
        user=require("MYSQL_USER"),
        password=os.environ.get("MYSQL_PASSWORD", ""),
        database=require("MYSQL_DB"),
        charset="utf8mb4",
        autocommit=True,  # we only run SELECTs here
        connect_timeout=int(os.environ.get("MYSQL_CONNECT_TIMEOUT", 15)),
    )
    with conn.cursor() as cur:
        cur.execute("SET time_zone = '+00:00'")
    return conn


def get_mongo_client():
    """MongoClient for the source MongoDB. Caller owns close."""
    import pymongo

    return pymongo.MongoClient(
        require("MONGO_URI"),
        serverSelectionTimeoutMS=int(os.environ.get("MONGO_TIMEOUT_MS", 15000)),
        appname="banking-pipeline",
    )


def get_databricks_connection():
    """Databricks SQL connection via the official pure-Python connector (no JVM)."""
    from databricks import sql

    kwargs = dict(
        server_hostname=require("DATABRICKS_HOST"),
        http_path=require("DATABRICKS_HTTP_PATH"),
        access_token=require("DATABRICKS_TOKEN"),
        catalog=os.environ.get("DATABRICKS_CATALOG", "main"),
    )
    schema = os.environ.get("DATABRICKS_SCHEMA")
    if schema:
        kwargs["schema"] = schema
    return sql.connect(**kwargs)


_DBX_TRANSIENT = (
    "cannot create the resource",
    "resource_exhausted",
    "please try again later",
    "rate limit",
    "too many requests",
    "service unavailable",
    "temporarily unavailable",
    "clusternotready",
    "worker environment",
    "rpc token bucket",
)


def databricks_transient(err: BaseException) -> bool:
    """True for warehouse capacity/throttle failures that heal on their own."""
    if isinstance(err, (ConnectionError, TimeoutError)):
        return True
    message = str(err).lower()
    return any(marker in message for marker in _DBX_TRANSIENT)


def dbx_call(label: str, fn: Callable[[], T]) -> T:
    """Run one Databricks SQL call, retrying transient errors with backoff.

    The connector never retries HTTP 400, and a warehouse that is still launching
    compute answers 400 RESOURCE_EXHAUSTED, so without this one capacity blip
    fails the whole extract step.
    """
    attempts = max(1, int(os.environ.get("DATABRICKS_MAX_ATTEMPTS", "4")))
    base = float(os.environ.get("DATABRICKS_RETRY_BASE_SECONDS", "5"))
    attempt = 0
    while True:
        attempt += 1
        try:
            return fn()
        except Exception as err:  # noqa: BLE001 - only transient errors are swallowed
            if attempt >= attempts or not databricks_transient(err):
                raise
            delay = min(base * 2 ** (attempt - 1), 60.0)
            logger.warning(
                "[%s] transient Databricks error, attempt %d/%d, retrying in %.0fs: %s",
                label,
                attempt,
                attempts,
                delay,
                err,
            )
            time.sleep(delay)


# --------------------------------------------------------------------------
# Spark JDBC / connector settings (secrets stay OUT of the URL)
# --------------------------------------------------------------------------


def mysql_jdbc() -> dict:
    """Spark JDBC options for the MySQL source.

    useCursorFetch=true  -> rows are streamed in `fetchsize` chunks. Without it
                            MySQL Connector/J loads the WHOLE result set into
                            memory (the classic OOM on multi-million-row tables).
    zeroDateTimeBehavior -> legacy '0000-00-00' dates become NULL instead of crashing.
    serverTimezone       -> timezone the MySQL server stores DATETIME in.
                            Set MYSQL_SERVER_TZ (e.g. Asia/Kolkata) if not UTC.
    """
    params = {
        "useCursorFetch": "true",
        "zeroDateTimeBehavior": "CONVERT_TO_NULL",
        "tinyInt1isBit": "false",
        "yearIsDateType": "false",
        "characterEncoding": "UTF-8",
        "serverTimezone": os.environ.get("MYSQL_SERVER_TZ", "UTC"),
        "sslMode": os.environ.get("MYSQL_SSL_MODE", "PREFERRED"),
        "connectTimeout": "30000",
    }
    query = "&".join(f"{k}={v}" for k, v in params.items())
    host, port, db = (
        require("MYSQL_HOST"),
        os.environ.get("MYSQL_PORT", "3306"),
        require("MYSQL_DB"),
    )
    return {
        "url": f"jdbc:mysql://{host}:{port}/{db}?{query}",
        "user": require("MYSQL_USER"),
        "password": os.environ.get("MYSQL_PASSWORD", ""),
        "driver": "com.mysql.cj.jdbc.Driver",
    }


def pg_jdbc() -> dict:
    """Spark JDBC options for the PostgreSQL warehouse.

    reWriteBatchedInserts=true -> multi-row INSERTs (3-5x faster writes).
    stringtype=unspecified     -> lets Spark strings land in jsonb/uuid columns.
    """
    host, port, db = (
        require("PG_HOST"),
        os.environ.get("PG_PORT", "5432"),
        require("PG_DB"),
    )
    return {
        "url": (
            f"jdbc:postgresql://{host}:{port}/{db}"
            "?reWriteBatchedInserts=true&stringtype=unspecified&ApplicationName=banking-spark"
        ),
        "user": require("PG_USER"),
        "password": os.environ.get("PG_PASS", ""),
        "driver": "org.postgresql.Driver",
    }


def mongo_settings() -> dict:
    """Settings for the MongoDB Spark connector."""
    return {"uri": require("MONGO_URI"), "database": os.environ.get("MONGO_DB_NAME")}
