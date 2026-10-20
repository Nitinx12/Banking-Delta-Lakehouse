"""SMTP sender for alerts and the pipeline summary.

Settings come from the repo's existing SMTP_* / ALERT_EMAIL_* variables, not
Airflow's [smtp] config, so the mail path is independent of the Airflow
provider. `python -m banking_airflow.notify --test` sends one line to prove the
path works before a real run.
"""

from __future__ import annotations

import logging
import os
import smtplib
import ssl
from dataclasses import dataclass
from email.message import EmailMessage
from pathlib import Path

log = logging.getLogger("banking.airflow.notify")

_TEMPLATES = Path(__file__).parent / "templates"


@dataclass(frozen=True)
class SmtpSettings:
    host: str
    port: int
    user: str
    password: str
    mail_from: str
    to: str
    prefix: str
    starttls: bool
    use_ssl: bool


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def settings() -> SmtpSettings:
    """Read SMTP settings; raise a clear error when the mail path is unconfigured."""
    host = _env("SMTP_HOST")
    if not host:
        raise RuntimeError("SMTP_HOST is not set; cannot send mail")
    user = _env("SMTP_USER")
    mail_from = _env("ALERT_EMAIL_FROM") or _env("SMTP_MAIL_FROM") or user
    to = _env("ALERT_EMAIL_TO") or mail_from
    return SmtpSettings(
        host=host,
        port=int(_env("SMTP_PORT", "587")),
        user=user,
        password=_env("SMTP_PASSWORD"),
        mail_from=mail_from,
        to=to,
        prefix=_env("ALERT_SUBJECT_PREFIX", "[banking-delta]"),
        starttls=_env("SMTP_STARTTLS", "true").lower() == "true",
        use_ssl=_env("SMTP_SSL", "false").lower() == "true",
    )


def build_message(
    cfg: SmtpSettings, subject: str, html: str, text: str, to: str | None
) -> EmailMessage:
    """Build a multipart/alternative message (text + HTML)."""
    msg = EmailMessage()
    msg["Subject"] = f"{cfg.prefix} {subject}".strip()
    msg["From"] = cfg.mail_from
    msg["To"] = to or cfg.to
    msg.set_content(text)
    msg.add_alternative(html, subtype="html")
    return msg


def send_email(subject: str, html: str, text: str, to: str | None = None) -> None:
    cfg = settings()
    msg = build_message(cfg, subject, html, text, to)
    ctx = ssl.create_default_context()
    if cfg.use_ssl:
        server = smtplib.SMTP_SSL(cfg.host, cfg.port, context=ctx, timeout=30)
    else:
        server = smtplib.SMTP(cfg.host, cfg.port, timeout=30)
        if cfg.starttls:
            server.starttls(context=ctx)
    with server:
        if cfg.user or cfg.password:
            server.login(cfg.user, cfg.password)
        server.send_message(msg)
    log.info("Sent mail to %s (subject=%s)", msg["To"], msg["Subject"])


def _render(name: str, **values: object) -> str:
    from jinja2 import Environment, FileSystemLoader

    env = Environment(
        loader=FileSystemLoader(str(_TEMPLATES)), autoescape=name.endswith(".html.j2")
    )
    return env.get_template(name).render(**values)


def send_task_failure(context: dict) -> None:
    """One task-failure mail on final failure. Logged, never raised."""
    ti = context.get("task_instance")
    dag_id = getattr(context.get("dag"), "dag_id", "unknown")
    task_id = getattr(ti, "task_id", "unknown")
    run_id = context.get("run_id") or getattr(context.get("dag_run"), "run_id", "")
    try_number = getattr(ti, "try_number", None)
    max_tries = getattr(ti, "max_tries", None)
    start = getattr(ti, "start_date", None)
    end = getattr(ti, "end_date", None)
    exception = context.get("exception")
    exc_class = type(exception).__name__ if exception else "unknown"

    values = {
        "dag_id": dag_id,
        "task_id": task_id,
        "run_id": run_id,
        "try_number": try_number,
        "max_tries": max_tries,
        "start": start,
        "end": end,
        "duration": _duration(start, end),
        "exception_class": exc_class,
        "base_url": str(context.get("base_url", "")).rstrip("/"),
        "retry_safe": not task_id.endswith("_tests"),
        "guide": "airflow/AIRFLOW_AGENT_GUIDE.md §14.4",
    }
    subject = f"[FAILED] {dag_id}.{task_id} (try {try_number}/{max_tries})"
    send_email(
        subject,
        _render("failure.html.j2", **values),
        _render("failure.txt.j2", **values),
    )


def _duration(start, end) -> str:
    try:
        if not start or not end:
            return "—"
        total = int((end - start).total_seconds())
    except (TypeError, AttributeError, ValueError):
        return "—"
    minutes, seconds = divmod(total, 60)
    return f"{minutes}m {seconds:02d}s" if minutes else f"{seconds}s"


def _main() -> int:
    logging.basicConfig(level=logging.INFO)
    import sys

    if "--test" not in sys.argv:
        log.error("Usage: python -m banking_airflow.notify --test")
        return 2
    send_email(
        "[TEST] Banking-Delta Airflow SMTP check",
        "<p>Banking-Delta Airflow SMTP check.</p>",
        "Banking-Delta Airflow SMTP check.",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
