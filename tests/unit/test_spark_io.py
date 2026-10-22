"""Tests for spark_io watermark normalization and timezone handling."""

from __future__ import annotations

import pytest

from src.utils.spark_io import _norm_ts


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
