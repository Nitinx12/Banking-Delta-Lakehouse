"""Local Spark must not heartbeat before its block manager is initialized."""

from __future__ import annotations

import sys
import threading
import types
from pathlib import Path
from types import SimpleNamespace

import pytest

from src.utils import engine
from src.utils.engine import (
    _await_executor,
    _clean_packages,
    _flatten_jars,
    _have_source_jars,
    _java_executable,
    _java_major,
    _packages,
    _prepare_environment,
    _silence_windows_kill,
    _stability_config,
    check_runtime,
    get_spark,
)

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


class TestJavaDiscovery:
    def test_java_home_candidate_is_preferred(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        exe = tmp_path / "bin" / ("java.exe" if engine.os.name == "nt" else "java")
        exe.parent.mkdir()
        exe.write_text("")
        monkeypatch.setenv("JAVA_HOME", str(tmp_path))
        monkeypatch.setattr(engine.shutil, "which", lambda name: "/usr/bin/java")

        assert _java_executable() == str(exe)

    def test_missing_java_home_falls_back_to_path(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.setenv("JAVA_HOME", str(tmp_path / "missing"))
        monkeypatch.setattr(engine.shutil, "which", lambda name: "/usr/bin/java")

        assert _java_executable() == "/usr/bin/java"

    def test_returns_none_when_java_is_absent(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.delenv("JAVA_HOME", raising=False)
        monkeypatch.setattr(engine.shutil, "which", lambda name: None)

        assert _java_executable() is None

    @pytest.mark.parametrize(
        ("stderr", "expected"),
        [
            ('openjdk version "17.0.2" 2022-01-18', 17),
            ('java version "1.8.0_292"', 8),
            ('openjdk version "11"', 11),
            ("no version here", None),
        ],
    )
    def test_java_major_parses_version(
        self, monkeypatch: pytest.MonkeyPatch, stderr: str, expected
    ) -> None:
        monkeypatch.setattr(
            engine.subprocess,
            "run",
            lambda *a, **k: SimpleNamespace(stderr=stderr),
        )

        assert _java_major("java") == expected

    def test_java_major_returns_none_when_java_cannot_run(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        def _boom(*a, **k):
            raise OSError("cannot execute")

        monkeypatch.setattr(engine.subprocess, "run", _boom)

        assert _java_major("java") is None


class TestCheckRuntime:
    def test_missing_java_raises_with_hint(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(engine, "_java_executable", lambda: None)

        with pytest.raises(RuntimeError, match="Java not found"):
            check_runtime()

    def test_unsupported_java_major_raises(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(engine, "_java_executable", lambda: "java")
        monkeypatch.setattr(engine, "_java_major", lambda java: 7)

        with pytest.raises(RuntimeError, match="Java 7 is not supported"):
            check_runtime()

    def test_supported_java_passes(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(engine, "_java_executable", lambda: "java")
        monkeypatch.setattr(engine, "_java_major", lambda java: 17)
        monkeypatch.setattr(engine, "_pyspark_version", lambda: (3, 5))
        monkeypatch.setenv("HADOOP_HOME", "/opt/hadoop")

        check_runtime()

    def test_unknown_java_version_is_tolerated(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(engine, "_java_executable", lambda: "java")
        monkeypatch.setattr(engine, "_java_major", lambda java: None)
        monkeypatch.setattr(engine, "_pyspark_version", lambda: (3, 5))
        monkeypatch.setenv("HADOOP_HOME", "/opt/hadoop")

        check_runtime()

    def test_other_pyspark_version_warns(
        self, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
    ) -> None:
        monkeypatch.setattr(engine, "_java_executable", lambda: "java")
        monkeypatch.setattr(engine, "_java_major", lambda java: 17)
        monkeypatch.setattr(engine, "_pyspark_version", lambda: (4, 0))
        monkeypatch.setenv("HADOOP_HOME", "/opt/hadoop")

        with caplog.at_level("WARNING"):
            check_runtime()

        assert any("Tested with PySpark 3.5.x" in r.message for r in caplog.records)


class TestEnvironmentAndPackages:
    def test_prepare_environment_pins_interpreter(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.delenv("SPARK_LOCAL_IP", raising=False)

        _prepare_environment()

        assert engine.os.environ["PYSPARK_PYTHON"] == sys.executable
        assert engine.os.environ["PYSPARK_DRIVER_PYTHON"] == sys.executable
        assert engine.os.environ["SPARK_LOCAL_IP"] == "127.0.0.1"

    @pytest.mark.parametrize(
        ("raw", "expected"),
        [
            ("g:a:1,g:b:2", "g:a:1,g:b:2"),
            ("g:a:1,  # empty = none\n ,  g:b:2", "g:a:1,g:b:2"),
            ("not-a-coordinate,g:a:1", "g:a:1"),
            ("", ""),
        ],
    )
    def test_clean_packages(self, raw: str, expected: str) -> None:
        assert _clean_packages(raw) == expected

    def test_packages_env_override_wins(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("SPARK_JARS_PACKAGES", "g:override:1")

        assert _packages(("mysql",)) == "g:override:1"

    def test_packages_resolve_scala_suffix(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.delenv("SPARK_JARS_PACKAGES", raising=False)
        monkeypatch.setattr(engine, "_pyspark_version", lambda: (3, 5))

        assert _packages(("postgres",)) == engine._POSTGRES_PKG
        assert "mongo-spark-connector_2.12" in _packages(("mongodb",))

    def test_packages_use_scala_213_on_spark4(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.delenv("SPARK_JARS_PACKAGES", raising=False)
        monkeypatch.setattr(engine, "_pyspark_version", lambda: (4, 0))

        assert "mongo-spark-connector_2.13" in _packages(("mongodb",))

    def test_unknown_source_raises(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv("SPARK_JARS_PACKAGES", raising=False)
        monkeypatch.setattr(engine, "_pyspark_version", lambda: (3, 5))

        with pytest.raises(ValueError, match="Unknown source"):
            _packages(("oracle",))

    def test_flatten_jars_returns_none_before_download(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.setattr(engine, "PROJECT_ROOT", tmp_path)

        assert _flatten_jars() is None

    def test_flatten_jars_joins_cached_jars(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        jars = tmp_path / ".spark" / "ivy" / "jars"
        jars.mkdir(parents=True)
        (jars / "b.jar").write_text("")
        (jars / "a.jar").write_text("")
        monkeypatch.setattr(engine, "PROJECT_ROOT", tmp_path)

        result = _flatten_jars()

        assert result == f"{jars / 'a.jar'},{jars / 'b.jar'}"

    def test_have_source_jars_checks_markers(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        jars = tmp_path / ".spark" / "ivy" / "jars"
        jars.mkdir(parents=True)
        (jars / "postgresql-42.7.4.jar").write_text("")
        monkeypatch.setattr(engine, "PROJECT_ROOT", tmp_path)

        assert _have_source_jars(("postgres",)) is True
        assert _have_source_jars(("mysql",)) is False
        assert _have_source_jars(("postgres", "mysql")) is False
        assert _have_source_jars(("unknown",)) is True


class TestSilenceWindowsKill:
    def test_noop_on_posix(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(
            engine, "os", SimpleNamespace(name="posix", environ=engine.os.environ)
        )

        _silence_windows_kill()  # must not raise or import pyspark

    def test_wraps_taskkill_once(self, monkeypatch: pytest.MonkeyPatch) -> None:
        import pyspark.java_gateway as gateway

        calls: list[tuple[tuple, dict]] = []

        def _fake_popen(args, *rest, **kwargs):
            calls.append((args, kwargs))
            return "proc"

        monkeypatch.setattr(gateway, "Popen", _fake_popen)

        _silence_windows_kill()
        wrapper = gateway.Popen
        _silence_windows_kill()

        assert gateway.Popen is wrapper
        assert getattr(wrapper, "_banking_quiet", False) is True
        assert wrapper(["taskkill", "/f", "/pid", "1"]) == "proc"
        assert calls[0][1]["stdout"] is engine.subprocess.DEVNULL
        assert calls[0][1]["stderr"] is engine.subprocess.DEVNULL
        wrapper(["other.exe"])
        assert "stdout" not in calls[1][1]

    def test_import_failure_is_tolerated(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setitem(sys.modules, "pyspark.java_gateway", None)

        _silence_windows_kill()


class TestAwaitExecutor:
    def test_returns_when_probe_succeeds(self) -> None:
        class _Spark:
            def range(self, n: int):
                return self

            def count(self) -> int:
                return 1

        _await_executor(_Spark(), timeout_seconds=5)

    def test_probe_error_is_reraised(self) -> None:
        class _Spark:
            def range(self, n: int):
                return self

            def count(self) -> int:
                raise RuntimeError("executor died")

        with pytest.raises(RuntimeError, match="executor died"):
            _await_executor(_Spark(), timeout_seconds=5)

    def test_hung_probe_times_out(self) -> None:
        release = threading.Event()

        class _Spark:
            def range(self, n: int):
                return self

            def count(self) -> int:
                release.wait(2)
                return 1

        try:
            with pytest.raises(RuntimeError, match="not ready after 0s"):
                _await_executor(_Spark(), timeout_seconds=0)
        finally:
            release.set()


class _Builder:
    def __init__(self, spark) -> None:
        self.spark = spark
        self.configs: list[tuple[str, str]] = []
        self.app_name: str | None = None
        self.master_name: str | None = None

    def appName(self, name: str) -> "_Builder":
        self.app_name = name
        return self

    def master(self, name: str) -> "_Builder":
        self.master_name = name
        return self

    def config(self, key: str, value: str) -> "_Builder":
        self.configs.append((key, value))
        return self

    def getOrCreate(self):
        return self.spark


class _FakeSparkContext:
    def __init__(self) -> None:
        self.level: str | None = None
        self.master = "local[*]"

    def setLogLevel(self, level: str) -> None:
        self.level = level


class _FakeSpark:
    version = "3.5.1"

    def __init__(self) -> None:
        self.sparkContext = _FakeSparkContext()


class TestGetSpark:
    def _install(self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> _Builder:
        fake = _FakeSpark()
        builder = _Builder(fake)
        module = types.ModuleType("pyspark.sql")
        module.SparkSession = SimpleNamespace(builder=builder)
        monkeypatch.setitem(sys.modules, "pyspark.sql", module)
        monkeypatch.setattr(engine, "PROJECT_ROOT", tmp_path)
        monkeypatch.setattr(engine, "check_runtime", lambda: None)
        monkeypatch.setattr(engine, "_prepare_environment", lambda: None)
        monkeypatch.setattr(engine, "_silence_windows_kill", lambda: None)
        monkeypatch.setattr(
            engine, "_await_executor", lambda spark, timeout_seconds=60: None
        )
        monkeypatch.setattr(engine.os, "cpu_count", lambda: 8)
        monkeypatch.delenv("SPARK_MASTER", raising=False)
        monkeypatch.delenv("SPARK_JARS_PACKAGES", raising=False)
        return builder

    def test_builds_configured_session_with_cached_jars(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        builder = self._install(monkeypatch, tmp_path)
        monkeypatch.setattr(engine, "_have_source_jars", lambda sources: True)
        monkeypatch.setattr(engine, "_flatten_jars", lambda: "a.jar,b.jar")

        spark = get_spark("my-app", sources=("postgres",))

        assert spark is builder.spark
        assert builder.app_name == "my-app"
        assert builder.master_name == "local[*]"
        config = dict(builder.configs)
        assert config["spark.sql.session.timeZone"] == "UTC"
        assert config["spark.jars"] == "a.jar,b.jar"
        assert config["spark.sql.shuffle.partitions"] == "8"
        assert config["spark.executor.heartbeatInterval"] == "600s"
        assert spark.sparkContext.level == "WARN"

    def test_resolves_packages_when_jars_are_missing(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        builder = self._install(monkeypatch, tmp_path)
        monkeypatch.setattr(engine, "_have_source_jars", lambda sources: False)

        get_spark(sources=("mysql",))

        config = dict(builder.configs)
        assert config["spark.jars.packages"] == engine._MYSQL_PKG

    def test_packages_override_is_used(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        builder = self._install(monkeypatch, tmp_path)
        monkeypatch.setenv("SPARK_JARS_PACKAGES", "g:override:1")
        monkeypatch.setattr(engine, "_have_source_jars", lambda sources: True)

        get_spark(sources=("postgres",))

        config = dict(builder.configs)
        assert config["spark.jars.packages"] == "g:override:1"
        assert "spark.jars" not in config

    def test_no_packages_when_no_sources(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        builder = self._install(monkeypatch, tmp_path)
        monkeypatch.setattr(engine, "_have_source_jars", lambda sources: False)

        get_spark(sources=())

        config = dict(builder.configs)
        assert "spark.jars.packages" not in config
        assert "spark.jars" not in config

    def test_master_and_memory_env_override(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        builder = self._install(monkeypatch, tmp_path)
        monkeypatch.setenv("SPARK_MASTER", "local[2]")
        monkeypatch.setenv("SPARK_DRIVER_MEMORY", "2g")
        monkeypatch.setattr(engine, "_have_source_jars", lambda sources: True)

        get_spark(sources=("postgres",))

        config = dict(builder.configs)
        assert builder.master_name == "local[2]"
        assert config["spark.driver.memory"] == "2g"
