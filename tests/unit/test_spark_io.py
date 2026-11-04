"""Tests for spark_io: identifiers, watermarks, readers, staging promotion."""

from __future__ import annotations

import datetime as dt
import json
from contextlib import contextmanager
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
import pytest
from psycopg2 import sql

from src.utils import spark_io
from src.utils.spark_io import _norm_ts

pytestmark = pytest.mark.unit


# --------------------------------------------------------------------- fakes
class _Cursor:
    """DB-API cursor stand-in: records calls, serves canned rows."""

    def __init__(self, rows=()) -> None:
        self.rows = list(rows)
        self.calls: list[tuple] = []
        self.rowcount = 0

    def __enter__(self) -> "_Cursor":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def execute(self, query, params=None) -> None:
        self.calls.append((query, params))

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return self.rows


class _Conn:
    def __init__(self, rows=()) -> None:
        self.cur = _Cursor(rows)
        self.closed = False

    def cursor(self) -> _Cursor:
        return self.cur

    def close(self) -> None:
        self.closed = True


class _MongoCollection:
    def __init__(self, doc=None, count: int = 0) -> None:
        self.doc = doc
        self.count = count
        self.find_one_calls: list[tuple] = []
        self.count_filters: list[dict] = []

    def find_one(self, flt, projection, sort):
        self.find_one_calls.append((flt, projection, sort))
        return self.doc

    def count_documents(self, flt) -> int:
        self.count_filters.append(flt)
        return self.count


class _MongoClient:
    def __init__(self, doc=None, count: int = 0) -> None:
        self.coll = _MongoCollection(doc, count)
        self.closed = False

    def __getitem__(self, name: str) -> "_MongoDB":
        return _MongoDB(self.coll)

    def close(self) -> None:
        self.closed = True


class _MongoDB:
    def __init__(self, coll: _MongoCollection) -> None:
        self.coll = coll

    def __getitem__(self, name: str) -> _MongoCollection:
        return self.coll


def _render(node) -> str:
    """Best-effort SQL text for psycopg2 Composables (no connection available)."""
    if isinstance(node, str):
        return node
    if isinstance(node, sql.SQL):
        return node.string
    if isinstance(node, sql.Identifier):
        return ".".join(node._wrapped)
    if isinstance(node, sql.Composed):
        return "".join(_render(part) for part in node.seq)
    return type(node).__name__


class TestNormTs:
    """Tests for _norm_ts function - canonical UTC format."""

    def test_norm_ts_with_z_suffix(self):
        """ISO format with Z suffix becomes canonical UTC with +00:00."""
        assert _norm_ts("2024-05-01T10:00:00Z") == "2024-05-01 10:00:00+00:00"
        assert (
            _norm_ts("2024-05-01T10:00:00.123456Z")
            == "2024-05-01 10:00:00.123456+00:00"
        )

    def test_norm_ts_with_t_separator(self):
        """ISO format with T separator becomes canonical UTC with +00:00."""
        assert _norm_ts("2024-05-01T10:00:00") == "2024-05-01 10:00:00+00:00"
        assert (
            _norm_ts("2024-05-01T10:00:00.123456") == "2024-05-01 10:00:00.123456+00:00"
        )

    def test_norm_ts_with_space_separator(self):
        """Space-separated format becomes canonical UTC with +00:00."""
        assert _norm_ts("2024-05-01 10:00:00") == "2024-05-01 10:00:00+00:00"
        assert (
            _norm_ts("2024-05-01 10:00:00.123456") == "2024-05-01 10:00:00.123456+00:00"
        )

    def test_norm_ts_already_canonical(self):
        """Already canonical format (with +00:00) is preserved."""
        assert _norm_ts("2024-05-01 10:00:00+00:00") == "2024-05-01 10:00:00+00:00"
        assert (
            _norm_ts("2024-05-01 10:00:00.123456+00:00")
            == "2024-05-01 10:00:00.123456+00:00"
        )

    def test_norm_ts_invalid_format(self):
        """Invalid format raises ValueError."""
        with pytest.raises(ValueError, match="Bad timestamp watermark"):
            _norm_ts("invalid")
        with pytest.raises(ValueError, match="Bad timestamp watermark"):
            _norm_ts("")
        with pytest.raises(ValueError, match="Bad timestamp watermark"):
            _norm_ts("2024-05-01")  # date only, not timestamp

    def test_norm_ts_microseconds_preserved(self):
        """Microseconds are preserved in normalization."""
        assert _norm_ts("2024-05-01T10:00:00.123Z") == "2024-05-01 10:00:00.123+00:00"
        assert (
            _norm_ts("2024-05-01T10:00:00.123456Z")
            == "2024-05-01 10:00:00.123456+00:00"
        )
        assert (
            _norm_ts("2024-05-01T10:00:00.1234567Z")
            == "2024-05-01 10:00:00.1234567+00:00"
        )


class TestIdentifiers:
    @pytest.mark.parametrize("name", ["accounts", "a_1", "x$y", "_t"])
    def test_mysql_identifier_accepts_safe_names(self, name: str) -> None:
        assert spark_io._ident(name) == name

    @pytest.mark.parametrize("name", ["", "1abc", "a-b", "a b", 'a"b'])
    def test_mysql_identifier_rejects_unsafe_names(self, name: str) -> None:
        with pytest.raises(ValueError, match="Unsafe or empty identifier"):
            spark_io._ident(name)

    @pytest.mark.parametrize("name", ["accounts", "_stg_accounts"])
    def test_pg_identifier_accepts_lower_snake_case(self, name: str) -> None:
        assert spark_io._pg_ident(name) == name

    @pytest.mark.parametrize("name", ["Accounts", "", None, "a-b"])
    def test_pg_identifier_rejects_other_names(self, name) -> None:
        with pytest.raises(ValueError, match="lower_snake_case"):
            spark_io._pg_ident(name)

    def test_databricks_identifier_rejects_unsafe_names(self) -> None:
        with pytest.raises(ValueError, match="Unsafe or empty Databricks"):
            spark_io._dbx_ident("bad-name")

    def test_databricks_qualified_uses_catalog_env(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("DATABRICKS_CATALOG", "main")
        cfg = {"source_schema": "public", "source_table": "branches"}

        assert spark_io._dbx_qualified(cfg) == "`main`.`public`.`branches`"

    def test_databricks_qualified_keeps_three_part_schema(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("DATABRICKS_CATALOG", "ignored")
        cfg = {"source_schema": "cat.public", "source_table": "branches"}

        assert spark_io._dbx_qualified(cfg) == "`cat`.`public`.`branches`"

    def test_staging_name_truncates_to_postgres_limit(self) -> None:
        schema, name = spark_io.staging_name(
            {"target_schema": "raw", "target_table": "t" * 80}
        )

        assert schema == "raw"
        assert name == ("_stg_" + "t" * 80)[:63]
        assert len(name) == 63


class TestLiterals:
    def test_mysql_numeric_literal_passes_through(self) -> None:
        assert spark_io._mysql_literal("numeric", "-12.5") == "-12.5"

    def test_mysql_numeric_literal_rejects_text(self) -> None:
        with pytest.raises(ValueError, match="Bad numeric watermark"):
            spark_io._mysql_literal("numeric", "1; DROP TABLE x")

    def test_mysql_timestamp_literal_is_quoted_and_normalised(self) -> None:
        assert (
            spark_io._mysql_literal("timestamp", "2024-05-01T10:00:00Z")
            == "'2024-05-01 10:00:00+00:00'"
        )

    def test_mysql_objectid_literal_is_rejected(self) -> None:
        with pytest.raises(ValueError, match="MySQL does not support"):
            spark_io._mysql_literal("objectid", "64b000000000000000000000")

    def test_mongo_numeric_value_is_typed(self) -> None:
        assert spark_io._mongo_value("numeric", "7") == 7
        assert spark_io._mongo_value("numeric", "7.5") == 7.5

    def test_mongo_timestamp_value_is_extended_json(self) -> None:
        assert spark_io._mongo_value("timestamp", "2024-05-01 10:00:00") == {
            "$date": "2024-05-01T10:00:00+00:00Z"
        }

    def test_mongo_objectid_value_is_extended_json(self) -> None:
        oid = "64b000000000000000000000"
        assert spark_io._mongo_value("objectid", oid) == {"$oid": oid}

    @pytest.mark.parametrize(
        ("strategy", "value"),
        [("objectid", "nope"), ("numeric", "abc"), ("unknown", "1")],
    )
    def test_mongo_value_rejects_bad_input(self, strategy: str, value: str) -> None:
        with pytest.raises(ValueError, match="watermark"):
            spark_io._mongo_value(strategy, value)

    def test_dbx_numeric_and_timestamp_literals(self) -> None:
        assert spark_io._dbx_literal("numeric", "42") == "42"
        assert (
            spark_io._dbx_literal("timestamp", "2024-05-01 10:00:00+00:00")
            == "TIMESTAMP'2024-05-01 10:00:00+00:00'"
        )

    def test_dbx_date_only_literal(self) -> None:
        assert (
            spark_io._dbx_literal("timestamp", "2024-05-01") == "TIMESTAMP'2024-05-01'"
        )

    def test_dbx_objectid_literal_is_rejected(self) -> None:
        with pytest.raises(ValueError, match="Databricks does not support"):
            spark_io._dbx_literal("objectid", "64b000000000000000000000")


class TestMysqlTypeMapping:
    @pytest.mark.parametrize(
        ("args", "expected"),
        [
            (("decimal", "decimal(10,2)", None, 12, 3, None), "numeric(12,3)"),
            (("decimal", None, None, None, None, None), "numeric(10,0)"),
            (("datetime", "datetime", None, None, None, 6), "timestamp(6)"),
            (("timestamp", "timestamp", None, None, None, None), "timestamptz"),
            (("char", "char(2)", 2, None, None, None), "char(2)"),
            (("char", "char", None, None, None, None), "char(1)"),
            (("varchar", "varchar(50)", 50, None, None, None), "varchar(50)"),
            (("varchar", "varchar", None, None, None, None), "text"),
            (("bit", "bit(1)", None, 1, None, None), "bit(1)"),
            (("bit", "bit", None, None, None, None), "bit"),
            (("int", "int unsigned", None, None, None, None), "bigint"),
            (("bigint", "bigint unsigned", None, None, None, None), "numeric(20,0)"),
            (("tinyint", "tinyint(1)", None, None, None, None), "smallint"),
            (("mediumint", "mediumint", None, None, None, None), "integer"),
            (("json", "json", None, None, None, None), "jsonb"),
            (("enum", "enum('a','b')", None, None, None, None), "text"),
            (("blob", "blob", None, None, None, None), "bytea"),
            (("geometry", "geometry", None, None, None, None), "text"),
        ],
    )
    def test_mysql_types_map_to_postgres(self, args: tuple, expected: str) -> None:
        assert spark_io._mysql_pg_type(*args) == expected


class TestMaxWatermarks:
    def test_mysql_watermark_formats_datetime(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        conn = _Conn([(dt.datetime(2024, 5, 1, 10, 0, 0, 123456),)])
        monkeypatch.setattr(spark_io, "get_mysql_connection", lambda: conn)
        cfg = {
            "incremental_column": "updated_at",
            "source_schema": "bank",
            "source_table": "accounts",
        }

        assert spark_io.mysql_max_watermark(cfg) == "2024-05-01 10:00:00.123456+00:00"
        assert conn.closed
        assert "MAX(`updated_at`)" in conn.cur.calls[0][0]

    def test_mysql_watermark_none_when_table_empty(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(spark_io, "get_mysql_connection", lambda: _Conn([(None,)]))
        cfg = {
            "incremental_column": "id",
            "source_schema": "bank",
            "source_table": "t",
        }

        assert spark_io.mysql_max_watermark(cfg) is None

    def test_mongo_watermark_formats_naive_datetime(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        client = _MongoClient(doc={"_id": dt.datetime(2024, 5, 1, 10, 0, 0)})
        monkeypatch.setattr(spark_io, "get_mongo_client", lambda: client)
        cfg = {
            "incremental_column": "_id",
            "source_schema": "bank",
            "source_table": "loans",
        }

        assert spark_io.mongo_max_watermark(cfg) == "2024-05-01 10:00:00.000000+00:00"
        assert client.closed
        assert client.coll.find_one_calls[0][2] == [("_id", -1)]

    def test_mongo_watermark_none_when_collection_empty(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(spark_io, "get_mongo_client", lambda: _MongoClient())
        cfg = {
            "incremental_column": "_id",
            "source_schema": "bank",
            "source_table": "loans",
        }

        assert spark_io.mongo_max_watermark(cfg) is None

    @pytest.mark.parametrize(
        ("value", "expected"),
        [
            (None, None),
            (dt.date(2024, 5, 1), "2024-05-01"),
            (dt.datetime(2024, 5, 1, 10, 0), "2024-05-01 10:00:00.000000+00:00"),
            (
                dt.datetime(
                    2024, 5, 1, 12, 0, tzinfo=dt.timezone(dt.timedelta(hours=2))
                ),
                "2024-05-01 10:00:00.000000+00:00",
            ),
            ("text-watermark", "text-watermark"),
        ],
    )
    def test_databricks_watermark_normalises_values(
        self, monkeypatch: pytest.MonkeyPatch, value, expected
    ) -> None:
        monkeypatch.setattr(
            spark_io, "dbx_call", lambda label, fn: value, raising=False
        )
        cfg = {
            "incremental_column": "id",
            "source_schema": "public",
            "source_table": "t",
        }

        assert spark_io.databricks_max_watermark(cfg) == expected


class TestWhereBuilders:
    def test_mysql_where_is_empty_for_full_load(self) -> None:
        cfg = {"load_strategy": "full", "incremental_column": "id"}

        assert spark_io._mysql_where(cfg, "a", "b") == ""

    def test_mysql_where_uses_lte_for_end_only(self) -> None:
        cfg = {
            "load_strategy": "incremental",
            "incremental_column": "id",
            "watermark_strategy": "numeric",
        }

        assert spark_io._mysql_where(cfg, None, "10") == " WHERE `id` <= 10"

    def test_mysql_where_re_reads_the_boundary_row(self) -> None:
        cfg = {
            "load_strategy": "incremental",
            "incremental_column": "updated_at",
            "watermark_strategy": "timestamp",
        }

        where = spark_io._mysql_where(cfg, "2024-05-01 10:00:00", "2024-05-02 10:00:00")

        assert "`updated_at` >= '2024-05-01 10:00:00+00:00'" in where
        assert "`updated_at` <= '2024-05-02 10:00:00+00:00'" in where

    def test_mongo_window_is_empty_for_full_load(self) -> None:
        cfg = {"load_strategy": "full", "incremental_column": "_id"}

        assert spark_io._mongo_window(cfg, None, None) == {}

    def test_mongo_window_builds_extended_json_filter(self) -> None:
        cfg = {
            "load_strategy": "incremental",
            "incremental_column": "_id",
            "watermark_strategy": "objectid",
        }
        oid = "64b000000000000000000000"

        window = spark_io._mongo_window(cfg, oid, oid)

        assert window == {"_id": {"$lte": {"$oid": oid}, "$gte": {"$oid": oid}}}

    def test_dbx_where_is_empty_for_full_load(self) -> None:
        cfg = {"load_strategy": "full", "incremental_column": "id"}

        assert spark_io._dbx_where(cfg, "2024-01-01", "2024-01-02") == ""

    def test_dbx_where_applies_lookback_window(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("DATABRICKS_LOOKBACK_MINUTES", "5")
        cfg = {
            "load_strategy": "incremental",
            "incremental_column": "updated_at",
            "watermark_strategy": "timestamp",
        }

        where = spark_io._dbx_where(
            cfg, "2024-05-01 10:00:00+00:00", "2024-05-02 10:00:00+00:00"
        )

        assert "`updated_at` <= TIMESTAMP'2024-05-02 10:00:00+00:00'" in where
        assert "`updated_at` >= TIMESTAMP'2024-05-01 09:55:00+00:00'" in where

    def test_dbx_where_falls_back_to_strict_comparison_on_bad_start(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("DATABRICKS_LOOKBACK_MINUTES", "1")
        cfg = {
            "load_strategy": "incremental",
            "incremental_column": "seq",
            "watermark_strategy": "numeric",
        }

        where = spark_io._dbx_where(cfg, "42", "100")

        assert "`seq` > 42" in where


class TestCountsAndColumns:
    def test_mysql_count_returns_int_and_where(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        conn = _Conn([(7,)])
        monkeypatch.setattr(spark_io, "get_mysql_connection", lambda: conn)
        cfg = {
            "source_schema": "bank",
            "source_table": "accounts",
            "load_strategy": "incremental",
            "incremental_column": "id",
            "watermark_strategy": "numeric",
        }

        assert spark_io.mysql_count(cfg, None, "10") == 7
        assert "WHERE `id` <= 10" in conn.cur.calls[0][0]

    def test_mongodb_count_passes_window_filter(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        client = _MongoClient(count=42)
        monkeypatch.setattr(spark_io, "get_mongo_client", lambda: client)
        cfg = {
            "source_schema": "bank",
            "source_table": "loans",
            "load_strategy": "incremental",
            "incremental_column": "_id",
            "watermark_strategy": "objectid",
        }
        oid = "64b000000000000000000000"

        from bson import ObjectId

        assert spark_io.mongo_count(cfg, oid, oid) == 42
        assert client.coll.count_filters[0] == {
            "_id": {"$lte": ObjectId(oid), "$gte": ObjectId(oid)}
        }

    def test_mysql_column_types_uses_information_schema(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        conn = _Conn(
            [
                ("id", "bigint", "bigint unsigned", None, 20, 0, None),
                ("name", "varchar", "varchar(50)", 50, None, None, None),
            ]
        )
        monkeypatch.setattr(spark_io, "get_mysql_connection", lambda: conn)
        cfg = {"source_schema": "bank", "source_table": "accounts"}

        assert spark_io.mysql_column_types(cfg) == {
            "id": "numeric(20,0)",
            "name": "varchar(50)",
        }

    def test_mysql_bounds_returns_none_for_single_value(self, monkeypatch) -> None:
        monkeypatch.setattr(spark_io, "get_mysql_connection", lambda: _Conn([(5, 5)]))

        assert spark_io._mysql_bounds("s", "t", "id", "") is None

    def test_mysql_bounds_returns_lo_hi(self, monkeypatch) -> None:
        monkeypatch.setattr(spark_io, "get_mysql_connection", lambda: _Conn([(1, 100)]))

        assert spark_io._mysql_bounds("s", "t", "id", " WHERE x") == ("1", "100")

    def test_databricks_columns_stops_at_partition_section(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        conn = _Conn(
            [
                ("id", "bigint", None),
                ("name", "string", None),
                ("# Partitioning", None, None),
                ("id", "bigint", None),
            ]
        )
        monkeypatch.setattr(spark_io, "get_databricks_connection", lambda: conn)
        monkeypatch.setattr(spark_io, "dbx_call", lambda label, fn: fn())
        cfg = {"source_schema": "public", "source_table": "t"}

        assert spark_io._dbx_columns(cfg) == [("id", "bigint"), ("name", "string")]

    def test_databricks_count_returns_int(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        conn = _Conn([(11,)])
        monkeypatch.setattr(spark_io, "get_databricks_connection", lambda: conn)
        monkeypatch.setattr(spark_io, "dbx_call", lambda label, fn: fn())
        cfg = {
            "source_schema": "public",
            "source_table": "t",
            "load_strategy": "full",
            "incremental_column": "id",
        }

        assert spark_io.databricks_count(cfg) == 11
        assert "SELECT COUNT(*)" in conn.cur.calls[0][0]


class TestReaders:
    class _Reader:
        def __init__(self) -> None:
            self.options: dict[str, str] = {}
            self.fmt: str | None = None

        def format(self, fmt: str) -> "TestReaders._Reader":
            self.fmt = fmt
            return self

        def option(self, key: str, value: str) -> "TestReaders._Reader":
            self.options[key] = value
            return self

        def load(self) -> "TestReaders._Reader":
            return self

    class _Spark:
        def __init__(self) -> None:
            self.reader = TestReaders._Reader()

        @property
        def read(self):
            return _SparkReadStart(self.reader)

    def test_read_mysql_uses_partitions_when_bounds_known(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            spark_io,
            "mysql_jdbc",
            lambda: {
                "url": "jdbc:mysql://x",
                "user": "u",
                "password": "p",
                "driver": "d",
            },
        )
        monkeypatch.setattr(spark_io, "get_mysql_connection", lambda: _Conn([(1, 100)]))
        cfg = {
            "source_schema": "bank",
            "source_table": "accounts",
            "load_strategy": "full",
            "incremental_column": "id",
            "partition_column": "id",
            "num_partitions": 4,
            "fetch_size": 500,
        }
        spark = TestReaders._Spark()

        reader = spark_io.read_mysql(spark, cfg)

        assert reader.options["partitionColumn"] == "id"
        assert reader.options["lowerBound"] == "1"
        assert reader.options["upperBound"] == "100"
        assert reader.options["numPartitions"] == "4"
        assert reader.options["fetchsize"] == "500"

    def test_read_mysql_single_partition_without_bounds(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            spark_io,
            "mysql_jdbc",
            lambda: {"url": "u", "user": "u", "password": "p", "driver": "d"},
        )
        cfg = {
            "source_schema": "bank",
            "source_table": "accounts",
            "load_strategy": "full",
            "incremental_column": "id",
            "partition_column": "id",
            "num_partitions": 1,
        }
        spark = TestReaders._Spark()

        reader = spark_io.read_mysql(spark, cfg)

        assert "partitionColumn" not in reader.options
        assert reader.options["dbtable"] == "(SELECT * FROM `bank`.`accounts`) AS src"

    def test_read_mongo_adds_aggregation_pipeline_for_windows(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(spark_io, "mongo_settings", lambda: {"uri": "mongodb://x"})
        cfg = {
            "source_schema": "bank",
            "source_table": "loans",
            "load_strategy": "incremental",
            "incremental_column": "_id",
            "watermark_strategy": "objectid",
        }
        oid = "64b000000000000000000000"
        spark = TestReaders._Spark()

        reader = spark_io.read_mongo(spark, cfg, oid, oid)

        pipeline = json.loads(reader.options["aggregation.pipeline"])
        assert pipeline == [
            {"$match": {"_id": {"$lte": {"$oid": oid}, "$gte": {"$oid": oid}}}}
        ]

    def test_read_mongo_full_load_has_no_pipeline(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(spark_io, "mongo_settings", lambda: {"uri": "mongodb://x"})
        cfg = {
            "source_schema": "bank",
            "source_table": "loans",
            "load_strategy": "full",
            "incremental_column": "_id",
        }
        spark = TestReaders._Spark()

        reader = spark_io.read_mongo(spark, cfg)

        assert "aggregation.pipeline" not in reader.options


class _SparkReadStart:
    def __init__(self, reader) -> None:
        self.reader = reader

    def format(self, fmt: str):
        return self.reader.format(fmt)


class _ArrowCursor:
    def __init__(self, batches) -> None:
        self.batches = list(batches)
        self.calls: list[str] = []

    def __enter__(self) -> "_ArrowCursor":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def execute(self, query: str) -> None:
        self.calls.append(query)

    def fetchmany_arrow(self, n: int):
        return self.batches.pop(0) if self.batches else pa.table({})


class _ArrowConn:
    def __init__(self, batches) -> None:
        self.cur = _ArrowCursor(batches)
        self.closed = False

    def cursor(self):
        return self.cur

    def close(self) -> None:
        self.closed = True


class _ParquetSpark:
    def __init__(self) -> None:
        self.parquet_path: str | None = None

    @property
    def read(self):
        outer = self

        class _Read:
            def parquet(self, path: str):
                outer.parquet_path = path
                return ("df", path)

        return _Read()


class TestReadDatabricks:
    def test_read_databricks_streams_batches_to_parquet(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        batch = pa.table({"id": pa.array([1, 2], type=pa.int64())})
        conn = _ArrowConn([batch, pa.table({"id": pa.array([], type=pa.int64())})])
        empty = pa.table({"id": pa.array([], type=pa.int64())})
        conn.cur.batches = [batch, empty]
        monkeypatch.setattr(spark_io, "get_databricks_connection", lambda: conn)
        monkeypatch.setattr(spark_io, "dbx_call", lambda label, fn: fn())
        monkeypatch.setattr(spark_io, "_dbx_columns", lambda cfg: [("id", "bigint")])
        monkeypatch.setattr(spark_io, "PROJECT_ROOT", tmp_path)
        spark = _ParquetSpark()
        cfg = {
            "source_schema": "public",
            "source_table": "branches",
            "target_table": "branches",
            "load_strategy": "full",
        }

        result = spark_io.read_databricks(spark, cfg)

        out_file = (
            tmp_path / ".spark" / "tmp" / "databricks_branches" / "part-0.parquet"
        )
        assert result == ("df", str(out_file))
        assert pq.read_table(out_file).num_rows == 2
        assert "SELECT `id` FROM" in conn.cur.calls[0]

    def test_read_databricks_writes_empty_file_when_no_rows(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        conn = _ArrowConn([pa.table({"id": pa.array([], type=pa.int64())})])
        monkeypatch.setattr(spark_io, "get_databricks_connection", lambda: conn)
        monkeypatch.setattr(spark_io, "dbx_call", lambda label, fn: fn())
        monkeypatch.setattr(spark_io, "_dbx_columns", lambda cfg: [("id", "bigint")])
        monkeypatch.setattr(spark_io, "PROJECT_ROOT", tmp_path)
        spark = _ParquetSpark()
        cfg = {
            "source_schema": "public",
            "source_table": "branches",
            "target_table": "branches",
            "load_strategy": "full",
        }

        spark_io.read_databricks(spark, cfg)

        out_file = (
            tmp_path / ".spark" / "tmp" / "databricks_branches" / "part-0.parquet"
        )
        table = pq.read_table(out_file)
        assert table.num_rows == 0
        assert table.schema.field("id").type == pa.int64()

    def test_read_databricks_requires_columns(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(spark_io, "_dbx_columns", lambda cfg: [])
        cfg = {"source_schema": "public", "source_table": "missing"}

        with pytest.raises(RuntimeError, match="Cannot introspect"):
            spark_io.read_databricks(_ParquetSpark(), cfg)

    @pytest.mark.parametrize(
        ("sql_type", "arrow_type"),
        [
            ("bigint", pa.int64()),
            ("int", pa.int32()),
            ("smallint", pa.int16()),
            ("tinyint", pa.int8()),
            ("double", pa.float64()),
            ("float", pa.float32()),
            ("boolean", pa.bool_()),
            ("date", pa.date32()),
            ("timestamp", pa.timestamp("us", tz="UTC")),
            ("timestamp_ntz", pa.timestamp("us")),
            ("varchar(20)", pa.string()),
            ("decimal(10,2)", pa.decimal128(10, 2)),
            ("weird_type", pa.string()),
        ],
    )
    def test_dbx_arrow_type_mapping(self, sql_type: str, arrow_type) -> None:
        assert spark_io._dbx_arrow_type(sql_type) == arrow_type


class _PromoteCursor:
    """Serves staged/target columns and records every statement."""

    def __init__(self, conn: "_PromoteConn") -> None:
        self.conn = conn
        self.rowcount = 0
        self.calls: list[str] = []

    def __enter__(self) -> "_PromoteCursor":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def execute(self, query, params=None) -> None:
        text = _render(query)
        self.calls.append(text)
        if "pg_attribute" in text:
            table = (params or ("",))[0]
            if table == "raw._stg_events":
                self._rows = self.conn.staged_columns
            else:
                self._rows = self.conn.target_columns
            return
        if "CREATE TABLE" in text:
            self.conn.target_columns = list(self.conn.staged_columns)
        self._rows = []
        self.rowcount = self.conn.rowcount

    def fetchall(self):
        return getattr(self, "_rows", [])


class _PromoteConn:
    def __init__(self, staged, target, rowcount: int = 5) -> None:
        self.staged_columns = staged
        self.target_columns = target
        self.rowcount = rowcount
        self.cursor_obj = _PromoteCursor(self)

    def cursor(self) -> _PromoteCursor:
        return self.cursor_obj


class TestPromoteStaging:
    STAGED = [
        ("id", "bigint"),
        ("payload", "text"),
        ("_batch_id", "text"),
        ("_loaded_at", "timestamp"),
    ]

    def test_creates_target_with_types_jsonb_and_not_null(self) -> None:
        conn = _PromoteConn(self.STAGED, [])
        cfg = {
            "target_schema": "raw",
            "target_table": "events",
            "load_strategy": "full",
        }

        inserted = spark_io.promote_staging(
            conn,
            cfg,
            jsonb_columns=("payload",),
            column_types={"_loaded_at": "timestamptz(6)"},
        )

        assert inserted == 5
        joined = "\n".join(conn.cursor_obj.calls)
        assert "CREATE TABLE raw.events (LIKE raw._stg_events)" in joined
        assert (
            "ALTER TABLE raw.events ALTER COLUMN _loaded_at TYPE timestamptz(6)"
            in joined
        )
        assert "AT TIME ZONE 'UTC'" in joined
        assert "ALTER COLUMN payload TYPE jsonb" in joined
        assert "ALTER COLUMN _batch_id SET NOT NULL" in joined
        assert "ALTER COLUMN _loaded_at SET NOT NULL" in joined
        assert "TRUNCATE TABLE raw.events" in joined
        assert "INSERT INTO raw.events" in joined

    def test_adds_new_columns_to_existing_target(self) -> None:
        existing = [
            ("id", "bigint"),
            ("_batch_id", "text"),
            ("_loaded_at", "timestamp"),
        ]
        conn = _PromoteConn(self.STAGED, existing)
        cfg = {
            "target_schema": "raw",
            "target_table": "events",
            "load_strategy": "incremental",
            "business_key": "id",
            "incremental_column": "_loaded_at",
        }

        spark_io.promote_staging(conn, cfg, jsonb_columns=("payload",))

        joined = "\n".join(conn.cursor_obj.calls)
        assert "CREATE TABLE" not in joined
        assert "ADD COLUMN payload jsonb" in joined
        assert "ROW_NUMBER() OVER (PARTITION BY id ORDER BY _loaded_at DESC)" in joined
        assert "TRUNCATE" not in joined

    def test_incremental_without_business_key_plain_insert(self) -> None:
        existing = [
            ("id", "bigint"),
            ("payload", "text"),
            ("_batch_id", "text"),
            ("_loaded_at", "timestamp"),
        ]
        conn = _PromoteConn(self.STAGED, existing)
        cfg = {
            "target_schema": "raw",
            "target_table": "events",
            "load_strategy": "incremental",
        }

        spark_io.promote_staging(conn, cfg)

        joined = "\n".join(conn.cursor_obj.calls)
        assert "INSERT INTO raw.events" in joined
        assert "ROW_NUMBER()" not in joined
        assert "::jsonb" not in joined

    def test_casts_staging_text_to_existing_jsonb_target(self) -> None:
        existing = [
            ("id", "bigint"),
            ("payload", "jsonb"),
            ("_batch_id", "text"),
            ("_loaded_at", "timestamp"),
        ]
        conn = _PromoteConn(self.STAGED, existing)
        cfg = {
            "target_schema": "raw",
            "target_table": "events",
            "load_strategy": "full",
        }

        spark_io.promote_staging(conn, cfg)

        assert "payload::jsonb" in conn.cursor_obj.calls[-1]

    def test_missing_staging_table_raises(self) -> None:
        conn = _PromoteConn([], [])
        cfg = {
            "target_schema": "raw",
            "target_table": "events",
            "load_strategy": "full",
        }

        with pytest.raises(RuntimeError, match="not found or has no columns"):
            spark_io.promote_staging(conn, cfg)


class _WriteLog(list):
    def _record(self, *item):
        self.append(item)


class _WriteChain:
    def __init__(self, log: _WriteLog) -> None:
        self.log = log

    def format(self, fmt: str) -> "_WriteChain":
        self.log._record("format", fmt)
        return self

    def option(self, key: str, value: str) -> "_WriteChain":
        self.log._record("option", key, value)
        return self

    def mode(self, mode: str) -> "_WriteChain":
        self.log._record("mode", mode)
        return self

    def save(self) -> None:
        self.log._record("save")


class _WriteDF:
    def __init__(self, partitions: int, log: _WriteLog) -> None:
        self.partitions = partitions
        self.log = log
        self.coalesced_to: int | None = None

    class _RDD:
        def __init__(self, outer: "_WriteDF") -> None:
            self.outer = outer

        def getNumPartitions(self) -> int:
            return self.outer.partitions

    @property
    def rdd(self) -> "_WriteDF._RDD":
        return _WriteDF._RDD(self)

    def coalesce(self, n: int) -> "_WriteDF":
        self.coalesced_to = n
        return self

    @property
    def write(self) -> _WriteChain:
        return _WriteChain(self.log)


class TestWriteStaging:
    def test_write_staging_coalesces_and_sets_jdbc_options(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        log = _WriteLog()
        df = _WriteDF(partitions=16, log=log)
        monkeypatch.setattr(
            spark_io,
            "pg_jdbc",
            lambda: {
                "url": "jdbc:postgresql://x",
                "user": "u",
                "password": "p",
                "driver": "d",
            },
        )
        conn = _Conn([(5,)])

        @contextmanager
        def _pg_cursor():
            yield conn.cur

        monkeypatch.setattr("src.utils.session.pg_cursor", _pg_cursor)
        cfg = {"target_schema": "raw", "target_table": "events", "num_partitions": 4}

        written = spark_io.write_staging(df, cfg)

        assert written == 5
        assert df.coalesced_to == 4
        assert ("option", "dbtable", "raw._stg_events") in log
        assert ("option", "batchsize", "20000") in log
        assert ("mode", "overwrite") in log
        assert ("save",) in log

    def test_write_staging_keeps_partition_count_below_cap(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        log = _WriteLog()
        df = _WriteDF(partitions=2, log=log)
        monkeypatch.setattr(
            spark_io,
            "pg_jdbc",
            lambda: {"url": "u", "user": "u", "password": "p", "driver": "d"},
        )
        conn = _Conn([(1,)])

        @contextmanager
        def _pg_cursor():
            yield conn.cur

        monkeypatch.setattr("src.utils.session.pg_cursor", _pg_cursor)
        cfg = {"target_schema": "raw", "target_table": "events"}

        spark_io.write_staging(df, cfg)

        assert df.coalesced_to is None

    def test_drop_staging_issues_drop(self, monkeypatch: pytest.MonkeyPatch) -> None:
        executed: list[str] = []

        class _Cur(_Cursor):
            def execute(self, query, params=None) -> None:
                executed.append(_render(query))

        @contextmanager
        def _pg_cursor():
            yield _Cur()

        monkeypatch.setattr("src.utils.session.pg_cursor", _pg_cursor)

        spark_io.drop_staging({"target_schema": "raw", "target_table": "events"})

        assert executed == ["DROP TABLE IF EXISTS raw._stg_events"]
