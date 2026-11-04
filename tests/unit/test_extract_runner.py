"""Unit tests for the shared extract runner (window, promote, watermark, DQ gates)."""

from __future__ import annotations

import uuid
from contextlib import contextmanager
from dataclasses import dataclass

import pytest

from src.utils import extract_runner
from src.utils.extract_runner import Extractor, Prepared, Source, TableContext

pytestmark = pytest.mark.unit


@dataclass
class _FakeRun:
    table_run_id: uuid.UUID
    rows_extracted: int = 0
    rows_landed: int = 0
    watermark_start: str | None = None
    watermark_end: str | None = None
    skipped: str | None = None

    def skip(self, reason: str) -> None:
        self.skipped = reason


class _Recorder:
    """Collects calls into every collaborator the runner touches."""

    def __init__(self) -> None:
        self.runs: list[dict] = []
        self.writes: list = []
        self.promotions: list[dict] = []
        self.advanced: list[dict] = []
        self.dq: list[dict] = []
        self.dropped: list[dict] = []
        self.after_dq: list[int] = []

    def table_run(self, *args, **kwargs):
        @contextmanager
        def _cm():
            run = _FakeRun(table_run_id=uuid.uuid4())
            self.runs.append({"args": args, "kwargs": kwargs, "run": run})
            yield run

        return _cm()


@pytest.fixture
def recorder(monkeypatch: pytest.MonkeyPatch) -> _Recorder:
    rec = _Recorder()

    @contextmanager
    def _tx():
        yield object()

    monkeypatch.setattr(extract_runner, "table_run", rec.table_run)
    monkeypatch.setattr(extract_runner, "pg_transaction", _tx)
    monkeypatch.setattr(
        extract_runner,
        "write_staging",
        lambda df, cfg: rec.writes.append((df, cfg)) or 10,
    )
    monkeypatch.setattr(
        extract_runner,
        "promote_staging",
        lambda conn, cfg, **kw: rec.promotions.append({"cfg": cfg, **kw}) or 10,
    )
    monkeypatch.setattr(
        extract_runner,
        "advance_watermark",
        lambda *a, **k: rec.advanced.append({"args": a, **k}),
    )
    monkeypatch.setattr(extract_runner, "log_dq_result", lambda **k: rec.dq.append(k))
    monkeypatch.setattr(
        extract_runner, "drop_staging", lambda cfg: rec.dropped.append(cfg)
    )
    return rec


def _source(
    *,
    prepare=None,
    max_watermark=None,
    count=None,
    empty_message: str = "no rows with a value in '{column}'",
    max_workers: int | None = None,
) -> Source:
    return Source(
        name="mysql_source",
        app="extract_mysql",
        spark_sources=("mysql",),
        max_watermark=max_watermark or (lambda cfg: "2024-05-02 00:00:00"),
        count=count or (lambda cfg, s, e: 10),
        prepare=prepare
        or (
            lambda ctx: Prepared(
                df=object(),
                promote_kwargs={"jsonb_columns": ("payload",)},
                after_dq=rec_after_dq(ctx),
            )
        ),
        empty_message=empty_message,
        max_workers=max_workers,
    )


def rec_after_dq(ctx: TableContext):
    ctx.run.after_called = []

    def _after(expected: int) -> None:
        ctx.run.after_called.append(expected)

    return _after


def _cfg(**overrides) -> dict:
    cfg = {
        "config_id": 1,
        "load_strategy": "full",
        "source_schema": "bank",
        "source_table": "accounts",
        "incremental_column": "updated_at",
    }
    cfg.update(overrides)
    return cfg


class TestIndependentConnections:
    def test_distinct_transactions_are_independent(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        @contextmanager
        def _tx():
            yield object()

        monkeypatch.setattr(extract_runner, "pg_transaction", _tx)

        assert extract_runner._independent_connections() is True

    def test_shared_connection_is_not_independent(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        shared = object()

        @contextmanager
        def _tx():
            yield shared

        monkeypatch.setattr(extract_runner, "pg_transaction", _tx)

        assert extract_runner._independent_connections() is False

    def test_failure_is_treated_as_sequential(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        @contextmanager
        def _tx():
            raise RuntimeError("no database")
            yield  # pragma: no cover

        monkeypatch.setattr(extract_runner, "pg_transaction", _tx)

        assert extract_runner._independent_connections() is False


class TestExtractTable:
    def test_full_load_success_records_counts_and_dq(self, recorder: _Recorder) -> None:
        extractor = Extractor(_source())

        status = extractor.extract_table(object(), uuid.uuid4(), _cfg(), "t", 1)

        assert status == "SUCCESS"
        run = recorder.runs[0]["run"]
        assert run.rows_extracted == 10 and run.rows_landed == 10
        assert recorder.promotions[0]["jsonb_columns"] == ("payload",)
        assert recorder.dq[0]["status"] == "PASSED"
        assert recorder.dq[0]["records_failed"] == 0
        assert run.after_called == [10]
        assert recorder.advanced == []
        assert recorder.dropped

    def test_row_count_mismatch_warns_but_still_succeeds(
        self, recorder: _Recorder
    ) -> None:
        extractor = Extractor(_source(count=lambda cfg, s, e: 25))

        status = extractor.extract_table(object(), uuid.uuid4(), _cfg(), None, None)

        assert status == "SUCCESS"
        assert recorder.dq[0]["status"] == "WARNING"
        assert recorder.dq[0]["records_failed"] == 15
        assert recorder.runs[0]["run"].after_called == [25]

    def test_incremental_empty_source_skips(
        self, recorder: _Recorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(extract_runner, "get_watermark", lambda cid: None)
        extractor = Extractor(_source(max_watermark=lambda cfg: None))

        status = extractor.extract_table(
            object(), uuid.uuid4(), _cfg(load_strategy="incremental"), None, None
        )

        assert status == "SKIPPED"
        run = recorder.runs[0]["run"]
        assert run.skipped == "no rows with a value in 'updated_at'"
        assert recorder.writes == []

    def test_incremental_unchanged_watermark_skips(
        self, recorder: _Recorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            extract_runner,
            "get_watermark",
            lambda cid: {"last_watermark_value": "2024-05-01 00:00:00"},
        )
        extractor = Extractor(_source(max_watermark=lambda cfg: "2024-05-01 00:00:00"))

        status = extractor.extract_table(
            object(), uuid.uuid4(), _cfg(load_strategy="incremental"), None, None
        )

        assert status == "SKIPPED"
        assert recorder.runs[0]["run"].skipped == "no new data past the watermark"
        assert recorder.writes == []

    def test_incremental_advances_watermark_inside_load_transaction(
        self, recorder: _Recorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            extract_runner,
            "get_watermark",
            lambda cid: {"last_watermark_value": "2024-05-01 00:00:00"},
        )
        monkeypatch.setattr(
            extract_runner, "begin_batch", lambda cfg, s, e: {"lock_version": 3}
        )
        extractor = Extractor(_source(max_watermark=lambda cfg: "2024-05-02 00:00:00"))

        status = extractor.extract_table(
            object(), uuid.uuid4(), _cfg(load_strategy="incremental"), "task", 2
        )

        assert status == "SUCCESS"
        run = recorder.runs[0]["run"]
        assert run.watermark_start == "2024-05-01 00:00:00"
        assert run.watermark_end == "2024-05-02 00:00:00"
        assert recorder.advanced[0]["expected_lock_version"] == 3
        assert recorder.advanced[0]["args"][1] == "2024-05-02 00:00:00"
        assert recorder.runs[0]["kwargs"] == {
            "airflow_task_id": "task",
            "airflow_try_number": 2,
        }

    def test_incremental_first_run_starts_at_beginning(
        self, recorder: _Recorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(extract_runner, "get_watermark", lambda cid: None)
        monkeypatch.setattr(
            extract_runner, "begin_batch", lambda cfg, s, e: {"lock_version": 1}
        )
        extractor = Extractor(_source(max_watermark=lambda cfg: "2024-05-02 00:00:00"))

        extractor.extract_table(
            object(), uuid.uuid4(), _cfg(load_strategy="incremental"), None, None
        )

        assert recorder.runs[0]["run"].watermark_start is None

    def test_prepare_receives_window_and_run(
        self, recorder: _Recorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        seen: list[TableContext] = []
        monkeypatch.setattr(extract_runner, "get_watermark", lambda cid: None)
        monkeypatch.setattr(
            extract_runner, "begin_batch", lambda cfg, s, e: {"lock_version": 1}
        )

        def _prepare(ctx: TableContext) -> Prepared:
            seen.append(ctx)
            return Prepared(df=object())

        extractor = Extractor(
            _source(prepare=_prepare, max_watermark=lambda cfg: "2024-05-02 00:00:00")
        )

        extractor.extract_table(
            object(), uuid.uuid4(), _cfg(load_strategy="incremental"), None, None
        )

        assert seen[0].end == "2024-05-02 00:00:00"
        assert seen[0].label == "bank.accounts"
        assert seen[0].run is recorder.runs[0]["run"]


class _RunRecorder(_Recorder):
    """Recorder for Extractor.run tests with pipeline-level collaborators."""

    def __init__(self) -> None:
        super().__init__()
        self.pipeline_start: list[dict] = []
        self.pipeline_finished: list = []
        self.stale: list = []
        self.stopped = 0
        self.spark_calls: list[dict] = []


@pytest.fixture
def run_recorder(recorder: _Recorder, monkeypatch: pytest.MonkeyPatch) -> _RunRecorder:
    rec = _RunRecorder()
    rec.runs = recorder.runs
    monkeypatch.setattr(
        extract_runner,
        "fail_stale_runs",
        lambda **kw: rec.stale.append(kw),
    )
    monkeypatch.setattr(
        extract_runner,
        "start_pipeline_run",
        lambda **kw: rec.pipeline_start.append(kw) or uuid.uuid4(),
    )
    monkeypatch.setattr(
        extract_runner,
        "finish_pipeline_run",
        lambda rid: rec.pipeline_finished.append(rid),
    )
    monkeypatch.setattr(
        extract_runner,
        "get_spark_session",
        lambda app, sources: rec.spark_calls.append({"app": app, "sources": sources})
        or object(),
    )
    monkeypatch.setattr(
        extract_runner, "stop_spark", lambda: setattr(rec, "stopped", rec.stopped + 1)
    )
    return rec


def _patch_extract(
    monkeypatch: pytest.MonkeyPatch, outcomes: dict[str, str] | type[Exception]
):
    def _extract(self, spark, pipeline_run_id, cfg, task_id, try_number):
        if isinstance(outcomes, type) and issubclass(outcomes, Exception):
            raise outcomes("boom")
        return outcomes.get(cfg["source_table"], "SUCCESS")

    monkeypatch.setattr(Extractor, "extract_table", _extract)


class TestRun:
    def test_rejects_zero_parallelism(self, run_recorder: _RunRecorder) -> None:
        extractor = Extractor(_source())

        with pytest.raises(SystemExit):
            extractor.run(["--parallel", "0"])

    def test_nothing_enabled_is_a_noop_success(
        self, run_recorder: _RunRecorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(extract_runner, "get_enabled_tables", lambda name: [])
        extractor = Extractor(_source())

        assert extractor.run([]) == 0
        assert run_recorder.stopped == 1
        assert run_recorder.pipeline_finished  # manual runs always finalize
        assert run_recorder.spark_calls == []

    def test_success_path_starts_and_stops_pipeline(
        self, run_recorder: _RunRecorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(extract_runner, "get_enabled_tables", lambda name: [_cfg()])
        _patch_extract(monkeypatch, {"accounts": "SUCCESS"})
        extractor = Extractor(_source())

        assert extractor.run([]) == 0
        assert run_recorder.pipeline_start[0]["trigger_type"] == "manual"
        assert run_recorder.stale == [{"max_age_hours": 6}]
        assert run_recorder.spark_calls[0]["sources"] == ("mysql",)
        assert run_recorder.stopped == 1

    def test_dag_run_defers_finalize_unless_requested(
        self, run_recorder: _RunRecorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(extract_runner, "get_enabled_tables", lambda name: [_cfg()])
        _patch_extract(monkeypatch, {"accounts": "SUCCESS"})
        extractor = Extractor(_source())

        assert extractor.run(["--dag-id", "d", "--dag-run-id", "r"]) == 0

        assert run_recorder.pipeline_start[0]["trigger_type"] == "airflow"
        assert run_recorder.pipeline_finished == []

    def test_dag_run_finalize_flag_closes_pipeline(
        self, run_recorder: _RunRecorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(extract_runner, "get_enabled_tables", lambda name: [_cfg()])
        _patch_extract(monkeypatch, {"accounts": "SUCCESS"})
        extractor = Extractor(_source())

        extractor.run(["--dag-run-id", "r", "--finalize"])

        assert run_recorder.pipeline_finished

    def test_failed_table_returns_nonzero(
        self, run_recorder: _RunRecorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            extract_runner,
            "get_enabled_tables",
            lambda name: [
                _cfg(source_table="accounts"),
                _cfg(config_id=2, source_table="cards"),
            ],
        )
        _patch_extract(monkeypatch, {"accounts": "SUCCESS", "cards": "FAILED"})
        extractor = Extractor(_source())

        assert extractor.run(["--parallel", "1"]) == 1

    def test_exception_in_table_is_reported_as_failed(
        self, run_recorder: _RunRecorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(extract_runner, "get_enabled_tables", lambda name: [_cfg()])
        _patch_extract(monkeypatch, RuntimeError)
        extractor = Extractor(_source())

        assert extractor.run(["--parallel", "1"]) == 1

    def test_table_filter_warns_about_unknown_tables(
        self, run_recorder: _RunRecorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(extract_runner, "get_enabled_tables", lambda name: [_cfg()])
        called: list[str] = []

        def _extract(self, spark, pipeline_run_id, cfg, task_id, try_number):
            called.append(cfg["source_table"])
            return "SUCCESS"

        monkeypatch.setattr(Extractor, "extract_table", _extract)
        extractor = Extractor(_source())

        assert extractor.run(["--tables", "accounts", "ghost", "--parallel", "1"]) == 0
        assert called == ["accounts"]

    def test_parallel_downgrades_when_connections_are_shared(
        self, run_recorder: _RunRecorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            extract_runner,
            "get_enabled_tables",
            lambda name: [_cfg(source_table="a"), _cfg(config_id=2, source_table="b")],
        )
        monkeypatch.setattr(extract_runner, "_independent_connections", lambda: False)
        _patch_extract(monkeypatch, {"a": "SUCCESS", "b": "SUCCESS"})
        extractor = Extractor(_source())

        assert extractor.run(["--parallel", "2"]) == 0

    def test_source_max_workers_caps_parallelism(
        self, run_recorder: _RunRecorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            extract_runner,
            "get_enabled_tables",
            lambda name: [_cfg(source_table="a"), _cfg(config_id=2, source_table="b")],
        )
        _patch_extract(monkeypatch, {"a": "SUCCESS", "b": "SUCCESS"})
        extractor = Extractor(_source(max_workers=1))

        assert extractor.run(["--parallel", "4"]) == 0

    def test_airflow_try_number_is_passed_through(
        self, run_recorder: _RunRecorder, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("AIRFLOW_CTX_TASK_ID", "task")
        monkeypatch.setenv("AIRFLOW_CTX_TRY_NUMBER", "3")
        monkeypatch.setattr(extract_runner, "get_enabled_tables", lambda name: [_cfg()])
        seen: list[tuple] = []

        def _extract(self, spark, pipeline_run_id, cfg, task_id, try_number):
            seen.append((task_id, try_number))
            return "SUCCESS"

        monkeypatch.setattr(Extractor, "extract_table", _extract)
        extractor = Extractor(_source())

        extractor.run(["--parallel", "1"])

        assert seen == [("task", 3)]

    def test_run_source_delegates_to_extractor(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(Extractor, "run", lambda self, argv=None: 7)

        assert extract_runner.run_source(_source()) == 7
