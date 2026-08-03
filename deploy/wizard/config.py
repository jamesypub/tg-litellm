"""Persisted wizard answers — ~/.tgw/config-<envName>.json (NO secrets).

The config file lets a Ctrl-C'd `tgw models` run resume where it left off.
It stores only non-sensitive answers; secrets (the LiteLLM master key, any
Bedrock API key, client secrets) are NEVER written — they're prompted fresh
each run and passed through env only. (Spec §8; mirrors the ccwb-iam
tg_cli/config.py pattern.)

Keyed on the ENVIRONMENT NAME by default (`config-<envName>.json`) so two
installs on one machine targeting different envs (demo2, a customer) can't
silently cross-resume each other's answers. The neutral `config.json` is the
path when no env name is known yet (the fully-interactive first load, before
the wizard collects env_name). `load`/`save`/`clear` take an optional
`env_name`; omitting it uses the neutral path.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("TGW_CONFIG_HOME", Path.home() / ".tgw"))
# The neutral (env-unkeyed) path — used pre-env-resolution.
CONFIG_PATH = CONFIG_DIR / "config.json"

# Keys that must NEVER be persisted, even if a caller stuffs them into the
# answers dict. Defense-in-depth against a secret leaking to disk.
SECRET_KEYS = frozenset(
    {
        "litellm_master_key",
        "LITELLM_MASTER_KEY",
        "bedrock_api_key",
        "BEDROCK_API_KEY",
        "client_secret",
    }
)

# A file-name-safe env name: the config path is derived from it, so reject
# anything that could escape the directory or collide across envs.
_ENV_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def valid_env_name(env_name: str | None) -> bool:
    return bool(env_name) and bool(_ENV_NAME_RE.match(env_name or ""))


def config_path_for(env_name: str | None = None) -> Path:
    """The config file for a given env. Env-keyed (`config-<envName>.json`)
    when a safe name is known, else the neutral `config.json`. Honors
    TGW_CONFIG_HOME via CONFIG_DIR."""
    if valid_env_name(env_name):
        return CONFIG_DIR / f"config-{env_name}.json"
    return CONFIG_PATH


def _scrub(answers: dict) -> dict:
    # Drop secrets AND transient run-only keys. Convention: any leading-
    # underscore answer key is transient and never persisted (e.g. derived
    # gateway URL/key resolved fresh from handoff.$ENV.json each run).
    return {
        k: v
        for k, v in answers.items()
        if k not in SECRET_KEYS and not k.startswith("_")
    }


def load(env_name: str | None = None) -> dict:
    """Return persisted answers for this env, or {} if none / unreadable."""
    path = config_path_for(env_name)
    try:
        with path.open(encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def save(answers: dict, env_name: str | None = None) -> None:
    """Persist answers (secrets scrubbed) to the env-keyed config (or the
    neutral config.json when env_name is omitted). Atomic + 0600."""
    path = config_path_for(env_name)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    safe = _scrub(answers)
    tmp = path.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(safe, fh, indent=2, sort_keys=True)
        fh.write("\n")
    tmp.replace(path)
    # Owner-only — the file holds env names / gateway addresses / account data.
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def clear(env_name: str | None = None) -> None:
    """Remove the persisted config (used after a clean success)."""
    try:
        config_path_for(env_name).unlink()
    except FileNotFoundError:
        pass
