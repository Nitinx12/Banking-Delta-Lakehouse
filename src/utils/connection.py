"""Database connection factories for MySQL, MongoDB and PostgreSQL."""

import os
import psycopg2
import pymongo
import pymysql
from pymongo import MongoClient


def get_mysql_connection() -> pymysql.Connection:
    """Return a MySQL connection using env vars (no hardcoded creds)."""
    return pymysql.connect(
        host=os.environ["MYSQL_HOST"],
        port=int(os.environ.get("MYSQL_PORT", 3306)),
        user=os.environ["MYSQL_USER"],
        password=os.environ.get("MYSQL_PASSWORD", ""),
        database=os.environ["MYSQL_DB"],
        charset="utf8mb4",
        autocommit=False,
    )


def get_mongo_client() -> MongoClient:
    """Return a MongoClient for source MongoDB."""
    return pymongo.MongoClient(os.environ["MONGO_URI"])


def get_pg_connection() -> psycopg2.extensions.connection:
    """Return a PostgreSQL connection to the warehouse."""
    return psycopg2.connect(
        host=os.environ["PG_HOST"],
        port=int(os.environ.get("PG_PORT", 5432)),
        dbname=os.environ["PG_DB"],
        user=os.environ["PG_USER"],
        password=os.environ.get("PG_PASS", ""),
    )


def get_databricks_jdbc() -> str:
    """Return a Databricks JDBC URL built from env vars."""
    host = os.environ["DATABRICKS_HOST"]
    token = os.environ["DATABRICKS_TOKEN"]
    http_path = os.environ["DATABRICKS_HTTP_PATH"]
    catalog = os.environ.get("DATABRICKS_CATALOG", "main")
    schema = os.environ.get("DATABRICKS_SCHEMA_PUBLIC", "public")
    return f"jdbc:spark://{host}:443/default?transportMode=http&ssl=1&sslTrustAll=true&User-Agent=Claude&httpPath={http_path}&catalog={catalog}&schema={schema}&token={token}"
