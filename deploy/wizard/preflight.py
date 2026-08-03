"""Read-only preflight — Python version + AWS identity (spec §4 phase 1).

Nothing here mutates anything. It fails early with a specific, friendly
message so the operator fixes the problem before any question is asked.
"""
from __future__ import annotations

import json
import subprocess
import sys

MIN_PYTHON = (3, 8)


def check_python() -> str | None:
    """Return an error message if the interpreter is too old, else None."""
    if sys.version_info < MIN_PYTHON:
        want = ".".join(str(n) for n in MIN_PYTHON)
        have = ".".join(str(n) for n in sys.version_info[:3])
        return f"Python {want}+ is required (found {have})."
    return None


def aws_identity(profile: str | None = None, region: str | None = None) -> dict:
    """Resolve the caller's AWS identity (read-only). Returns a dict with
    'account'/'arn' on success, or {'error': msg} on failure.
    """
    cmd = ["aws", "sts", "get-caller-identity", "--output", "json"]
    if profile:
        cmd += ["--profile", profile]
    if region:
        cmd += ["--region", region]
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30
        )
    except FileNotFoundError:
        return {"error": "the AWS CLI (`aws`) was not found on PATH."}
    except subprocess.TimeoutExpired:
        return {"error": "AWS identity check timed out after 30s."}
    if out.returncode != 0:
        stderr = (out.stderr or "").strip()
        return {"error": stderr or "could not resolve AWS credentials."}
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError:
        return {"error": "unexpected response from `aws sts get-caller-identity`."}
    return {"account": data.get("Account", ""), "arn": data.get("Arn", "")}


def sso_login_hint(profile: str | None) -> str:
    """The exact recovery line for expired/absent SSO creds (spec §5.4)."""
    p = f" --profile {profile}" if profile else ""
    return f"run `aws sso login{p}` (or refresh your credentials) and re-run."
