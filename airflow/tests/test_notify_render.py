"""Alerting: redaction, template rendering and the SMTP message shape."""

from __future__ import annotations

import pytest
from banking_airflow import notify
from banking_airflow.redact import redact

pytestmark = pytest.mark.unit

FAILURE_VALUES = {
    "dag_id": "banking_delta_daily",
    "task_id": "raw_tests",
    "run_id": "scheduled__2026-10-20T02:00",
    "try_number": 1,
    "max_tries": 1,
    "start": "2026-10-20 02:05:00",
    "end": "2026-10-20 02:05:30",
    "duration": "30s",
    "exception_class": "ValueError",
    "base_url": "https://airflow.example.com",
    "retry_safe": False,
    "guide": "airflow/AIRFLOW_AGENT_GUIDE.md §14.4",
}


def test_redact_strips_url_credentials():
    out = redact("connecting to postgresql://user:s3cret@db:5432/warehouse failed")
    assert "s3cret" not in out
    assert "***@" in out


def test_redact_strips_password_tokens():
    out = redact("password=hunter2 token=abc123secret")
    assert "hunter2" not in out
    assert "abc123secret" not in out


def test_redact_strips_long_base64_and_hex():
    out = redact("key " + "A" * 60 + " and " + "f" * 48)
    assert "A" * 60 not in out
    assert "f" * 48 not in out


def test_redact_truncates_to_300():
    assert len(redact("x" * 1000)) <= 301


def test_failure_templates_render_without_scripts():
    html = notify._render("failure.html.j2", **FAILURE_VALUES)
    text = notify._render("failure.txt.j2", **FAILURE_VALUES)
    assert "banking_delta_daily.raw_tests" in html
    assert "<script" not in html.lower()
    assert "no - fix the data first" in text


def test_settings_requires_host(monkeypatch):
    monkeypatch.delenv("SMTP_HOST", raising=False)
    with pytest.raises(RuntimeError):
        notify.settings()


def test_settings_reads_smtp_vars(monkeypatch):
    monkeypatch.setenv("SMTP_HOST", "smtp.example.com")
    monkeypatch.setenv("SMTP_PORT", "2525")
    monkeypatch.setenv("SMTP_USER", "bot@example.com")
    monkeypatch.setenv("SMTP_PASSWORD", "app-password")
    monkeypatch.setenv("ALERT_EMAIL_TO", "ops@example.com")
    monkeypatch.setenv("SMTP_SSL", "false")
    cfg = notify.settings()
    assert cfg.host == "smtp.example.com"
    assert cfg.port == 2525
    assert cfg.to == "ops@example.com"


def test_build_message_is_multipart_alternative(monkeypatch):
    monkeypatch.setenv("SMTP_HOST", "smtp.example.com")
    monkeypatch.setenv("SMTP_USER", "bot@example.com")
    monkeypatch.setenv("SMTP_PASSWORD", "app-password")
    monkeypatch.setenv("ALERT_EMAIL_TO", "ops@example.com")
    cfg = notify.settings()
    msg = notify.build_message(cfg, "hello", "<p>hi</p>", "hi", None)
    assert msg["Subject"].endswith("hello")
    assert msg.get_content_type() == "multipart/alternative"


def test_send_email_uses_smtplib(monkeypatch):
    monkeypatch.setenv("SMTP_HOST", "smtp.example.com")
    monkeypatch.setenv("SMTP_USER", "bot@example.com")
    monkeypatch.setenv("SMTP_PASSWORD", "app-password")
    monkeypatch.setenv("ALERT_EMAIL_TO", "ops@example.com")
    monkeypatch.setenv("SMTP_STARTTLS", "false")

    calls = {}

    class FakeServer:
        def __init__(self, host, port, timeout=None):
            calls["host"] = host

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def login(self, user, password):
            calls["login"] = user

        def send_message(self, msg):
            calls["sent"] = msg["Subject"]

    monkeypatch.setattr(notify.smtplib, "SMTP", FakeServer)
    notify.send_email("subject", "<p>h</p>", "t")
    assert calls["host"] == "smtp.example.com"
    assert calls["login"] == "bot@example.com"
    assert "subject" in calls["sent"]
