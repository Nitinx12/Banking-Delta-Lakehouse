"""Local Spark must not heartbeat before its block manager is initialized."""

from __future__ import annotations

import pytest

from src.utils.engine import _stability_config

pytestmark = pytest.mark.unit


def test_local_master_delays_first_heartbeat() -> None:
    """Local mode delays the beat that would carry a null BlockManagerId."""
    config = _stability_config("local[*]")

    assert config["spark.executor.heartbeatInterval"] == "600s"
    assert config["spark.network.timeout"] == "1200s"


@pytest.mark.parametrize("master", ["local", "local[2]", "local[*, 2]"])
def test_every_local_master_delays_first_heartbeat(master: str) -> None:
    config = _stability_config(master)

    assert "spark.executor.heartbeatInterval" in config


def test_local_timeout_exceeds_heartbeat_interval() -> None:
    """Spark requires the network timeout to be larger than the heartbeat."""
    config = _stability_config("local[1]")
    interval = int(config["spark.executor.heartbeatInterval"].rstrip("s"))
    timeout = int(config["spark.network.timeout"].rstrip("s"))

    assert timeout > interval


@pytest.mark.parametrize("master", ["spark://host:7077", "local-cluster[1,2,1024]"])
def test_cluster_master_keeps_default_heartbeat(master: str) -> None:
    """Executors in separate JVMs keep Spark's normal heartbeat tuning."""
    config = _stability_config(master)

    assert "spark.executor.heartbeatInterval" not in config
    assert config["spark.network.timeout"] == "600s"
