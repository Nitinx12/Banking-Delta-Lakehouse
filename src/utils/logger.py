"""Project logger - configured once, every module logs through a child logger."""

from __future__ import annotations

import logging
import os
import re
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path

from . import config  # noqa: F401  (ensures .env is loaded before LOG_LEVEL is read)

_ROOT = "banking"
_configured = False
_LOG_DIR = Path(__file__).resolve().parents[2] / "logs"


def _configure_root() -> None:
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

    logging.getLogger("py4j").setLevel(logging.WARNING)
    _configured = True


def _safe_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]", "_", name).replace(".", "_")


def get_logger(name: str | None = None) -> logging.Logger:
    """Return a logger under the 'banking' namespace (shared handler/format).

    Each distinct logger also gets its own rotating file in logs/, so a script's
    output is not mixed with every other module's.
    """
    _configure_root()

    if not name or name == _ROOT:
        logger = logging.getLogger(_ROOT)
        file_name = "banking.log"
    else:
        logger = logging.getLogger(f"{_ROOT}.{name}")
        file_name = f"{_safe_name(name.split('.')[-1])}.log"

    if not any(isinstance(h, RotatingFileHandler) for h in logger.handlers):
        _LOG_DIR.mkdir(parents=True, exist_ok=True)
        level = logging.getLogger(_ROOT).level
        handler = RotatingFileHandler(
            _LOG_DIR / file_name,
            maxBytes=10 * 1024 * 1024,
            backupCount=5,
            encoding="utf-8",
        )
        handler.setLevel(level)
        handler.setFormatter(
            logging.Formatter(
                fmt="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
                datefmt="%Y-%m-%d %H:%M:%S",
            )
        )
        logger.addHandler(handler)
        logger.propagate = True
    logger.setLevel(logging.getLogger(_ROOT).level)
    return logger
