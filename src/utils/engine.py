"""PySpark engine — one tuned, pre-flight-checked local SparkSession.

Design goals
------------
* Remove the usual JVM/Scala breakages BEFORE Spark starts (clear error messages):
    - Java missing / wrong version
    - Python worker != driver Python (venv mismatch)
    - Scala-suffix mismatch on connector jars (derived from the installed PySpark)
    - Windows paths with spaces breaking the Ivy cache (cache lives in the project)
    - VPN / multi-NIC hosts where Spark binds the wrong IP
* Load ONLY the JDBC/connector jars the current script needs.
* Sensible defaults for 100k-10M row extraction on one machine.

Requires: PySpark 3.5.x (Scala 2.12) + Java 17 (11 or 21 also work).
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable

from .config import PROJECT_ROOT
from .logger import get_logger

logger = get_logger(__name__)

# Maven coordinates (Scala suffix is added automatically where needed).
_POSTGRES_PKG = "org.postgresql:postgresql:42.7.4"
_MYSQL_PKG = "com.mysql:mysql-connector-j:8.4.0"
_MONGO_PKG = "org.mongodb.spark:mongo-spark-connector_{scala}:10.4.1"

_SOURCE_PACKAGES = {
    "postgres": _POSTGRES_PKG,
    "mysql": _MYSQL_PKG,
    "mongodb": _MONGO_PKG,
}

_SUPPORTED_JAVA = {8, 11, 17, 21}


# ------------------------------------------------------------------ pre-flight
def _java_executable() -> str | None:
    java_home = os.environ.get("JAVA_HOME")
    if java_home:
        candidate = Path(java_home) / "bin" / ("java.exe" if os.name == "nt" else "java")
        if candidate.exists():
            return str(candidate)
    return shutil.which("java")


def _java_major(java: str) -> int | None:
    try:
        out = subprocess.run([java, "-version"], capture_output=True, text=True, timeout=20).stderr
    except Exception:  # noqa: BLE001
        return None
    match = re.search(r'version "(\d+)(?:\.(\d+))?', out)
    if not match:
        return None
    major, minor = int(match.group(1)), match.group(2)
    return int(minor) if major == 1 and minor else major  # "1.8.0" -> 8


def _pyspark_version() -> tuple[int, int]:
    import pyspark

    major, minor, *_ = pyspark.__version__.split(".")
    return int(major), int(minor)


def check_runtime() -> None:
    """Fail fast, with actionable messages, if the JVM side cannot work."""
    java = _java_executable()
    if java is None:
        raise RuntimeError(
            "Java not found. Install JDK 17 (e.g. Temurin) and set JAVA_HOME "
            "(Windows: setx JAVA_HOME \"C:\\Program Files\\Eclipse Adoptium\\jdk-17...\")."
        )
    major = _java_major(java)
    if major is not None and major not in _SUPPORTED_JAVA:
        raise RuntimeError(f"Java {major} is not supported by Spark 3.5. Use JDK 17 (found: {java}).")

    py_major, py_minor = _pyspark_version()
    if (py_major, py_minor) != (3, 5):
        logger.warning(
            "Tested with PySpark 3.5.x; found %s.%s. Connector jars are pinned for Spark 3.5 / Scala 2.12.",
            py_major,
            py_minor,
        )

    if os.name == "nt" and not os.environ.get("HADOOP_HOME"):
        logger.warning(
            "HADOOP_HOME is not set (Windows). JDBC/Mongo jobs work, but writing parquet/csv "
            "to local disk needs winutils.exe. Not needed for this pipeline."
        )


def _prepare_environment() -> None:
    # Driver and workers MUST use the same interpreter (venv!).
    os.environ["PYSPARK_PYTHON"] = sys.executable
    os.environ["PYSPARK_DRIVER_PYTHON"] = sys.executable
    # Avoid binding to a VPN/virtual NIC ("Can't assign requested address").
    os.environ.setdefault("SPARK_LOCAL_IP", "127.0.0.1")


def _packages(sources: Iterable[str]) -> str:
    override = os.environ.get("SPARK_JARS_PACKAGES")
    if override is not None:  # explicit override (use "" to disable downloads)
        return override
    scala = "2.13" if _pyspark_version()[0] >= 4 else "2.12"
    unknown = set(sources) - set(_SOURCE_PACKAGES)
    if unknown:
        raise ValueError(f"Unknown source(s) {sorted(unknown)}; choose from {sorted(_SOURCE_PACKAGES)}")
    return ",".join(_SOURCE_PACKAGES[s].format(scala=scala) for s in sources)


# --------------------------------------------------------------------- session
def get_spark(app_name: str = "banking-pipeline", sources: Iterable[str] = ("postgres",)):
    """Return the SparkSession for this process (one per process; reused if it exists).

    sources: which jars to load, any of "postgres", "mysql", "mongodb".
             e.g. a MySQL extraction script uses sources=("mysql", "postgres").
    """
    sources = tuple(sources)
    check_runtime()
    _prepare_environment()

    from pyspark.sql import SparkSession

    cores = os.cpu_count() or 4
    spark_dir = PROJECT_ROOT / ".spark"
    for sub in ("ivy", "tmp", "warehouse"):
        (spark_dir / sub).mkdir(parents=True, exist_ok=True)

    jvm_opts = "-Duser.timezone=UTC -XX:+UseG1GC"
    builder = (
        SparkSession.builder.appName(app_name)
        .master(os.environ.get("SPARK_MASTER", "local[*]"))
        # --- memory / parallelism -------------------------------------------------
        .config("spark.driver.memory", os.environ.get("SPARK_DRIVER_MEMORY", "4g"))
        .config("spark.driver.maxResultSize", "1g")
        .config("spark.sql.shuffle.partitions", os.environ.get("SPARK_SHUFFLE_PARTITIONS", str(cores)))
        .config("spark.default.parallelism", str(cores))
        .config("spark.sql.adaptive.enabled", "true")
        .config("spark.sql.adaptive.coalescePartitions.enabled", "true")
        # --- correctness: everything in UTC (JVM + Spark SQL) ------------------------
        .config("spark.sql.session.timeZone", "UTC")
        .config("spark.driver.extraJavaOptions", jvm_opts)
        .config("spark.executor.extraJavaOptions", jvm_opts)
        # --- stability --------------------------------------------------------------
        .config("spark.driver.bindAddress", "127.0.0.1")
        .config("spark.driver.host", "127.0.0.1")
        .config("spark.network.timeout", "600s")
        .config("spark.executor.heartbeatInterval", "60s")
        # --- keep junk inside the project, not in cwd / user profile ---------------
        .config("spark.local.dir", str(spark_dir / "tmp"))
        .config("spark.sql.warehouse.dir", str(spark_dir / "warehouse"))
        .config("spark.jars.ivy", str(spark_dir / "ivy"))
        # --- less overhead ------------------------------------------------------------
        .config("spark.ui.enabled", os.environ.get("SPARK_UI_ENABLED", "false"))
        .config("spark.ui.showConsoleProgress", "false")
    )

    packages = _packages(sources)
    if packages:
        builder = builder.config("spark.jars.packages", packages)

    spark = builder.getOrCreate()
    spark.sparkContext.setLogLevel("WARN")
    logger.info("Spark %s ready | master=%s | jars=%s", spark.version, spark.sparkContext.master, packages or "none")
    return spark
