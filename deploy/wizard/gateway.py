"""Resolve the gateway URL + master key (spec §6 Q4, §9).

Path A: read handoff.$ENV.json (produced by `deploy.sh install`) — take
        gateway_url and read the master key from Secrets Manager via its ARN.
Path B: LITELLM_URL + LITELLM_MASTER_KEY supplied directly.

The master key is a SECRET: it is returned for the run's env only and is
never written to the resume config (config.SECRET_KEYS + the `_`-prefix
transient convention).
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

DEPLOY_DIR = Path(__file__).resolve().parent.parent


def handoff_path(env_name: str) -> Path:
    """Where the optional installer metadata lives for this env. Its presence
    is a shortcut, never a requirement (#115 Issue 4)."""
    return DEPLOY_DIR / f"handoff.{env_name}.json"


def export_hint() -> str:
    """The exact two exports the operator supplies when no handoff file exists.
    Printed once at startup (Phase 1) so the requirement is known before any
    question — not discovered late (#115 Issue 4)."""
    return (
        "export LITELLM_URL=https://<your-gateway-host>\n"
        "export LITELLM_MASTER_KEY=sk-<your-admin-key>"
    )


def _read_secret(arn: str, profile: str | None, region: str | None) -> str:
    cmd = [
        "aws", "secretsmanager", "get-secret-value",
        "--secret-id", arn, "--query", "SecretString", "--output", "text",
    ]
    if profile:
        cmd += ["--profile", profile]
    if region:
        cmd += ["--region", region]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if out.returncode != 0 or not out.stdout.strip():
        raise RuntimeError(
            (out.stderr or "").strip() or "could not read the master key secret."
        )
    return out.stdout.strip()


def resolve_from_handoff(env_name: str, profile: str | None, region: str | None) -> dict:
    """Path A (silent fallback). Returns {'url', 'key'} or raises RuntimeError.

    The handoff file is optional installer metadata (#115 Issue 4): a missing
    file is NOT an error condition here — callers only reach this after already
    confirming neither LITELLM_URL nor a handoff file was available, so the
    not-found message points back at the two exports rather than reading like a
    failure of a required file."""
    path = handoff_path(env_name)
    if not path.exists():
        raise RuntimeError(
            "the gateway address and admin key weren't supplied. Set them and "
            "re-run:\n"
            f"      {export_hint().replace(chr(10), chr(10) + '      ')}\n"
            f"    (Optional: `./deploy.sh {env_name} install` writes {path.name} "
            "so these are picked up automatically.)"
        )
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        raise RuntimeError(f"could not read {path.name}: {e}")

    url = data.get("gateway_url", "")
    arn = (data.get("secret_references", {}) or {}).get("master_key_secret_arn", "")
    if not url:
        raise RuntimeError(f"gateway_url missing from {path.name}.")
    if not arn:
        raise RuntimeError(f"master_key_secret_arn missing from {path.name}.")
    key = _read_secret(arn, profile, region)
    return {"url": url, "key": key}


def resolve_direct(url: str, key: str) -> dict:
    """Path B. Both supplied directly (key is a secret, never persisted)."""
    if not url or not key:
        raise RuntimeError("both a gateway address and an admin key are required.")
    return {"url": url, "key": key}
