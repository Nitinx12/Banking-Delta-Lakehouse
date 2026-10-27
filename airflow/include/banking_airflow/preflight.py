"""Connectivity and environment checks, run in the banking venv before a run.

Fails in seconds if a source, the warehouse or Java is unreachable instead of
30 minutes into Spark. Uses the project logger so failures read the same as the
pipeline's own logs; never prints credentials.
"""

from __future__ import annotations

import shutil
import socket

from utils.connection import (
    get_databricks_connection,
    get_mongo_client,
    get_mysql_connection,
    get_pg_connection,
)
from utils.logger import get_logger

log = get_logger(__name__)

SUPPORTED_JAVA_MAJORS = {8, 11, 17, 21}
MIN_FREE_BYTES = 5 * 1024**3


def _check_java() -> None:
    java = shutil.which("java")
    if not java:
        raise RuntimeError("java not found on PATH")
    import subprocess

    out = subprocess.run(
        [java, "-version"], check=False, capture_output=True, text=True, timeout=15
    ).stderr
    major = None
    for token in out.replace('"', " ").split():
        if token[:1].isdigit():
            major = int(token.split(".")[0])
            break
    if major is None:
        raise RuntimeError("could not parse the java version")
    if major not in SUPPORTED_JAVA_MAJORS:
        raise RuntimeError(
            f"java {major} is not supported (need {sorted(SUPPORTED_JAVA_MAJORS)})"
        )
    log.info("java %s ok", major)


def _check_disk() -> None:
    from pathlib import Path

    root = Path(__import__("os").environ.get("PROJECT_ROOT", "."))
    free = shutil.disk_usage(root).free
    if free < MIN_FREE_BYTES:
        raise RuntimeError(
            f"only {free / 1024**3:.1f} GB free under {root}; need >= 5 GB"
        )
    log.info("disk %.1f GB free", free / 1024**3)


def _check_warehouse() -> None:
    with get_pg_connection("airflow-preflight") as conn, conn.cursor() as cur:
        cur.execute("SELECT 1")
        cur.execute("SELECT to_regclass('audit.pipeline_runs')")
        if cur.fetchone()[0] is None:
            raise RuntimeError("audit.pipeline_runs is missing; run the SQL migrations")
    log.info("warehouse ok (audit.pipeline_runs present)")


def _check_mysql() -> None:
    conn = get_mysql_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
    finally:
        conn.close()
    log.info("mysql ok")


def _check_mongo() -> None:
    client = get_mongo_client()
    try:
        client.admin.command("ping")
    finally:
        client.close()
    log.info("mongo ok")


def _check_databricks() -> None:
    conn = get_databricks_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchall()
    finally:
        conn.close()
    log.info("databricks ok")


def _check_maven() -> None:
    with socket.create_connection(("repo1.maven.org", 443), timeout=10):
        pass
    log.info("maven reachable")


def _check_smtp() -> None:
    """Warn only: a mail problem must not fail the pipeline (the watchdog covers it)."""
    import os
    import smtplib

    host = os.environ.get("SMTP_HOST")
    if not host:
        log.warning("SMTP_HOST not set; summary mail will fail")
        return
    port = int(os.environ.get("SMTP_PORT", "587"))
    try:
        with smtplib.SMTP(host, port, timeout=10) as server:
            server.ehlo()
        log.info("smtp reachable")
    except OSError as exc:
        log.warning(
            "SMTP not reachable (%s); summary mail may fail", type(exc).__name__
        )


def main() -> int:
    checks = (
        ("java", _check_java),
        ("disk", _check_disk),
        ("warehouse", _check_warehouse),
        ("mysql", _check_mysql),
        ("mongo", _check_mongo),
        ("databricks", _check_databricks),
        ("maven", _check_maven),
    )
    for name, check in checks:
        try:
            check()
        except Exception as exc:  # noqa: BLE001 - one line per failing check, then exit non-zero
            log.error("preflight %s FAILED: %s", name, exc)
            return 1
    _check_smtp()
    log.info("preflight passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
