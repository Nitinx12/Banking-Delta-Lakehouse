"""Step-0 preflight: prove every source answers before the extract starts.

Databricks warehouses cold-start intermittently ("Cannot create the resource,
please try again later") and a Spark job burns ~25s of startup before it even
sees that error, so the per-table retries in the extract are too short to be
useful. A plain SELECT 1 with a capped backoff catches the same blip here, and
a source that stays down stops the run before any step touches it.
"""

from __future__ import annotations

import os
import random
import time
from collections.abc import Callable
from contextlib import closing
from dataclasses import dataclass

from .config import require
from .connection import get_mongo_client, get_mysql_connection, get_pg_connection
from .logger import get_logger

logger = get_logger(__name__)

# Credentials never heal on retry; everything else does, so give it the backoff.
_AUTH_MARKERS = (
    "unauthorized",
    "invalid access token",
    "invalid_access_token",
    "malformed access token",
    # what the SQL connector reports for a rejected token (seen live 2026-11-05)
    "credential was not sent",
    "access denied",
    "authentication failed",
    "invalid authentication",
    "permission denied",
)


class PreflightError(RuntimeError):
    """A source rejected the probe for a reason retrying cannot fix."""


def _is_auth_error(err: BaseException) -> bool:
    """True for credential / permission failures, which no amount of waiting fixes."""
    message = str(err).lower()
    return any(marker in message for marker in _AUTH_MARKERS)


def wait_until(
    name: str,
    check: Callable[[], None],
    timeout: float,
    base: float,
    cap: float,
) -> float:
    """Run `check` until it passes, backing off exponentially with jitter.

    An auth error raises immediately (retrying only burns the budget); any other
    error is retried until `timeout`, then TimeoutError carrying that last error.
    Returns how many seconds the successful attempt took.
    """
    deadline = time.monotonic() + timeout
    delay = base
    attempt = 0
    while True:
        attempt += 1
        started = time.monotonic()
        try:
            check()
        except Exception as err:
            if _is_auth_error(err):
                logger.error("%s preflight: auth error, not retrying: %s", name, err)
                raise PreflightError(f"{name}: {err}") from err
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(
                    f"{name}: no answer within {timeout:.0f}s after {attempt} "
                    f"attempt(s); last error: {err}"
                ) from err
            nap = min(delay * random.uniform(0.5, 1.0), remaining, cap)
            logger.warning(
                "%s preflight attempt %d failed in %.1fs, retrying in %.1fs: %s",
                name,
                attempt,
                time.monotonic() - started,
                nap,
                err,
            )
            time.sleep(nap)
            delay = min(delay * 2, cap)
        else:
            elapsed = time.monotonic() - started
            logger.info("%s preflight ok in %.1fs (attempt %d)", name, elapsed, attempt)
            return elapsed


def _check_postgres() -> None:
    """The warehouse must answer: every step writes its results there."""
    with closing(get_pg_connection("main_preflight")) as conn, conn.cursor() as cur:
        cur.execute("SELECT 1")


def _check_mysql() -> None:
    """MySQL source, opened the same way the extract opens it."""
    with closing(get_mysql_connection()) as conn, conn.cursor() as cur:
        cur.execute("SELECT 1")


def _check_mongodb() -> None:
    """MongoDB source: ping is the cheapest statement the server answers."""
    client = get_mongo_client()
    try:
        client.admin.command("ping")
    finally:
        client.close()


def _check_databricks() -> None:
    """SELECT 1 on the extract's warehouse, with the connector's retries off."""
    from databricks import sql

    kwargs: dict = {
        # Same host / http_path / token the extract uses (utils.connection reads
        # the same names), plus a near-zero connector retry budget so the
        # backoff in wait_until decides when to give up.
        "server_hostname": require("DATABRICKS_HOST"),
        "http_path": require("DATABRICKS_HTTP_PATH"),
        "access_token": require("DATABRICKS_TOKEN"),
        "catalog": os.environ.get("DATABRICKS_CATALOG", "main"),
        "_retry_stop_after_attempts_count": 1,
        "_retry_stop_after_attempts_duration": 1,
        "_retry_delay_default": 1,
        "_retry_delay_min": 0.1,
        "_retry_delay_max": 5.0,
    }
    schema = os.environ.get("DATABRICKS_SCHEMA")
    if schema:
        kwargs["schema"] = schema
    with closing(sql.connect(**kwargs)) as conn, conn.cursor() as cur:
        cur.execute("SELECT 1")
        cur.fetchone()


@dataclass(frozen=True)
class Probe:
    """One source check and the retry budget it gets."""

    name: str
    check: Callable[[], None]
    timeout: float
    base: float
    cap: float


def _seconds(env: str, default: float) -> float:
    """One tunable budget, overridable per run (short values are for testing)."""
    return float(os.environ.get(env, default))


def probes() -> list[Probe]:
    """Every source the pipeline needs: warehouse first, slowest timeout last."""
    slow = _seconds("PREFLIGHT_TIMEOUT", 60.0)
    base = _seconds("PREFLIGHT_BASE", 1.0)
    cap = _seconds("PREFLIGHT_CAP", 10.0)
    return [
        Probe("postgresql", _check_postgres, slow, base, cap),
        Probe("mysql", _check_mysql, slow, base, cap),
        Probe("mongodb", _check_mongodb, slow, base, cap),
        Probe(
            "databricks",
            _check_databricks,
            _seconds("PREFLIGHT_DATABRICKS_TIMEOUT", 300.0),
            _seconds("PREFLIGHT_DATABRICKS_BASE", 2.0),
            _seconds("PREFLIGHT_DATABRICKS_CAP", 30.0),
        ),
    ]


def run_preflight() -> None:
    """Probe every source in order; raise on the first one that stays down."""
    planned = probes()
    logger.info("Preflight: probing %s", ", ".join(p.name for p in planned))
    for probe in planned:
        wait_until(probe.name, probe.check, probe.timeout, probe.base, probe.cap)
    logger.info("Preflight: all %d source(s) reachable", len(planned))
