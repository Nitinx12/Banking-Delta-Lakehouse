# Dependencies & Integrations

The Banking-Delta-Lakehouse pipeline implements a multi-source ETL process (MySQL, MongoDB, Databricks) that lands data into a PostgreSQL warehouse using PySpark, which is then processed into Core and Mart layers.

## Third-Party Services
- **MySQL**: Source database. Connected via `pymysql` (Python) and `mysql-connector-j` (Spark JDBC).
- **MongoDB**: Source database. Connected via `pymongo` (Python) and `mongo-spark-connector` (Spark).
- **Databricks**: Source and final target. Connected via `databricks-sql-connector` (pure Python/Arrow) and `databricks-sdk`.
- **PostgreSQL**: Central warehouse (Landing $\rightarrow$ Staging $\rightarrow$ Core $\rightarrow$ Mart). Connected via `psycopg2` (Python) and `postgresql` JDBC driver (Spark).

## SDKs & Libraries
- **PySpark (3.5.x)**: Core engine for large-scale extraction and landing. Managed in `src/utils/engine.py:get_spark`.
- **psycopg2**: Used for warehouse metadata, audit logs, and promotion of staging tables (`src/utils/connection.py:get_pg_connection`).
- **pymysql / pymongo**: Used for lightweight source checks (e.g., calculating `MAX(watermark)`) in `src/utils/connection.py`.
- **databricks-sql-connector**: Used to extract data from Databricks via Arrow to local Parquet files (`src/utils/spark_io.py:read_databricks`).
- **PyArrow**: Handles high-performance data transfer between Databricks and Spark.

## Configuration & Environment
### Config Loading Logic
1. **Entry Point**: `src/utils/config.py` uses `python-dotenv` to load `.env` into `os.environ`.
2. **Project Root**: `src/utils/config.py:PROJECT_ROOT` resolves the repository root for relative pathing (e.g., `.spark/` cache).
3. **Strictness**: `src/utils/config.py:require()` enforces that critical environment variables are present at runtime.

### Key Environment Variables
| Category | Variables |
| :--- | :--- |
| **Databricks** | `DATABRICKS_HOST`, `DATABRICKS_TOKEN`, `DATABRICKS_HTTP_PATH`, `DATABRICKS_CATALOG` |
| **PostgreSQL** | `PG_HOST`, `PG_PORT`, `PG_DB`, `PG_USER`, `PG_PASS` |
| **MySQL** | `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DB` |
| **MongoDB** | `MONGO_URI`, `MONGO_DB_NAME` |
| **Spark** | `SPARK_DRIVER_MEMORY`, `SPARK_SHUFFLE_PARTITIONS`, `SPARK_MASTER` |
| **Pipeline** | `ENVIRONMENT`, `LOG_LEVEL`, `TIMEZONE` |

## How this connects to other parts
- **Jobs $\rightarrow$ Engine**: Jobs in `src/jobs/` call `get_spark()` in `src/utils/engine.py` to initialize the JVM with the correct JDBC jars.
- **Engine $\rightarrow$ Connection**: `src/utils/spark_io.py` uses `src/utils/connection.py` to generate JDBC URLs and credentials.
- **Spark $\rightarrow$ Postgres**: PySpark writes to `raw._stg_<table_name>`, which is then atomically promoted to the raw table via `psycopg2` in `src/utils/spark_io.py:promote_staging`.

## Open questions / UNVERIFIED
- **HADOOP_HOME**: The engine warns about missing `HADOOP_HOME` on Windows, but notes it is not needed for the current pipeline.
- **Airflow Secret Management**: `.env.airflow` exists, but the interaction between Airflow's internal connection registry and the pipeline's `.env` usage should be verified.
