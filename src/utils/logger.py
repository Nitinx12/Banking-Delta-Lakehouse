"""Project logger — one logger used by every module."""

import logging
import sys
from pathlib import Path


def get_logger(name: str = "banking") -> logging.Logger:
    """Return the project logger, configured once."""
    logger = logging.getLogger(name)
    if logger.handlers:
        return logger

    level_name = _level_from_env()
    logger.setLevel(level_name)

    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(level_name)
    handler.setFormatter(
        logging.Formatter(
            fmt="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )
    )
    logger.addHandler(handler)
    logger.propagate = False
    return logger


def _level_from_env() -> str:
    env_level = Path(".env")
    level = "INFO"
    if env_level.exists():
        for line in env_level.read_text().splitlines():
            if line.strip().startswith("LOG_LEVEL="):
                level = line.split("=", 1)[1].strip().strip('"').upper()
                break
    return level
