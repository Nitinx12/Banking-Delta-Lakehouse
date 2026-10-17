"""Project logger — configured once, every module logs through a child logger."""

from __future__ import annotations

import logging
import os
import sys

from . import config  # noqa: F401  (ensures .env is loaded before LOG_LEVEL is read)

_ROOT = "banking"
_configured = False


def _configure() -> None:
    global _configured
    if _configured:
        return

    level_name = os.environ.get("LOG_LEVEL", "INFO").strip().strip('"').upper()
    level = getattr(logging, level_name, None)
    if not isinstance(level, int):
        level = logging.INFO

    root = logging.getLogger(_ROOT)
    root.setLevel(level)
    root.propagate = False
    if not root.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(
            logging.Formatter(
                fmt="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
                datefmt="%Y-%m-%d %H:%M:%S",
            )
        )
        root.addHandler(handler)

    # py4j is very chatty at DEBUG and drowns real messages.
    logging.getLogger("py4j").setLevel(logging.WARNING)
    _configured = True


def get_logger(name: str | None = None) -> logging.Logger:
    """Return a logger under the 'banking' namespace (shared handler/format)."""
    _configure()
    if not name or name == _ROOT:
        return logging.getLogger(_ROOT)
    return logging.getLogger(f"{_ROOT}.{name}")
