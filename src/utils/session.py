"""Central session module — one import for MySQL, MongoDB and Databricks access."""

from __future__ import annotations

import os
from contextlib import contextmanager
from typing import Generator

import psycopg2
import pymongo
import pymysql
from pyspark.sql import SparkSession

from .connection import (
    get_databricks_jdbc,
    get_mongo_client,
    get_mysql_connection,
    get_pg_connection,
)
from .engine import get_spark
from .logger import get_logger

logger = get_logger(__name__)

_spark: SparkSession | None = None
_pg_conn: psycopg2.extensions.connection | None = None
_mysql_conn: pymysql.Connection | None = None
_mongo_client: pymongo.MongoClient | None = None


def get_spark_session() -> SparkSession:
    global _spark
    if _spark is None:
        _spark = get_spark()
    return _spark


def get_pg_cursor() -> tuple[psycopg2.extensions.connection, psycopg2.extensions.cursor]:
    global _pg_conn
    if _pg_conn is None:
        _pg_conn = get_pg_connection()
    return _pg_conn, _pg_conn.cursor()


def get_mysql_cursor() -> tuple[pymysql.Connection, pymysql.cursors.Cursor]:
    global _mysql_conn
    if _mysql_conn is None:
        _mysql_conn = get_mysql_connection()
    return _mysql_conn, _mysql_conn.cursor()


def get_mongo_collection(db_name: str | None = None) -> pymongo.collection.Collection:
    global _mongo_client
    if _mongo_client is None:
        _mongo_client = get_mongo_client()
    db = _mongo_client[db_name or os.environ["MONGO_DB_NAME"]]
    return db


def get_databricks_session() -> SparkSession:
    """Return a SparkSession configured for Databricks SQL (remote)."""
    return get_spark_session()


def get_databricks_jdbc_url() -> str:
    return get_databricks_jdbc()


@contextmanager
def mysql_cursor() -> Generator[tuple[pymysql.Connection, pymysql.cursors.Cursor], None, None]:
    conn, cur = get_mysql_cursor()
    try:
        yield conn, cur
    except Exception:
        conn.rollback()
        raise
    else:
        conn.commit()
    finally:
        cur.close()


@contextmanager
def pg_cursor() -> Generator[tuple[psycopg2.extensions.connection, psycopg2.extensions.cursor], None, None]:
    conn, cur = get_pg_cursor()
    try:
        yield conn, cur
    except Exception:
        conn.rollback()
        raise
    else:
        conn.commit()
    finally:
        cur.close()


def close_all_connections() -> None:
    if _spark is not None:
        _spark.stop()
        logger.info("Spark session stopped")
    if _pg_conn is not None:
        _pg_conn.close()
        logger.info("PostgreSQL connection closed")
    if _mysql_conn is not None:
        _mysql_conn.close()
        logger.info("MySQL connection closed")
    if _mongo_client is not None:
        _mongo_client.close()
        logger.info("MongoDB client closed")
