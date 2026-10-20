"""Redaction helpers shared by the alerting code.

Kept free of side effects so it can be unit-tested without a database. The
regex mirrors `src.utils.audit._redact`, which the pipeline uses when it writes
`audit.pipeline_errors`; we redact again on the way out so a compromise of the
audit table cannot leak a credential into an email.
"""

from __future__ import annotations

import re

_URL_CREDS_RE = re.compile(r"(?i)(://[^:/\s]+:)([^@\s]+)@")
_KV_RE = re.compile(r"(?i)\b(password|pwd|token|secret|api[_-]?key)=([^&;\s]+)")
_PEM_RE = re.compile(r"-----BEGIN [A-Z ]+-----[\s\S]*?-----END [A-Z ]+-----")
_LONG_B64_RE = re.compile(r"\b[A-Za-z0-9+/]{40,}={0,2}\b")
_LONG_HEX_RE = re.compile(r"\b[0-9a-fA-F]{32,}\b")

_MAX_LEN = 300


def redact(text: object) -> str:
    """Strip credentials from `text`; return at most 300 characters."""
    if text is None:
        return ""
    out = str(text)
    out = _PEM_RE.sub("<redacted-key>", out)
    out = _URL_CREDS_RE.sub(lambda m: f"{m.group(1)}***@", out)
    out = _KV_RE.sub(lambda m: f"{m.group(1)}=***", out)
    out = _LONG_B64_RE.sub("***", out)
    out = _LONG_HEX_RE.sub("***", out)
    if len(out) > _MAX_LEN:
        out = out[:_MAX_LEN] + "…"
    return out
