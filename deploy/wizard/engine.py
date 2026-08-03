"""The engine seam — build env, subprocess register-models.sh UNCHANGED.

This is the ONLY place the wizard touches the engine, and it touches it only
by (a) computing the environment variables register-models.sh already
documents, and (b) running it via subprocess. It never reads, edits, or
reimplements the script. (Spec §2, §11.)
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

# register-models.sh lives beside this package: deploy/register-models.sh.
DEPLOY_DIR = Path(__file__).resolve().parent.parent
REGISTER_SCRIPT = DEPLOY_DIR / "register-models.sh"

# Answer key -> env var register-models.sh reads. Only vars the script already
# documents in its header; the wizard SETS them, it does not change how the
# script consumes them.
_FAMILY_TO_SCOPE = {
    "Claude only": "claude",
    "OpenAI/Mantle only": "mantle",
    "Both Claude and OpenAI/Mantle": "both",
}


def build_env(answers: dict) -> dict:
    """Translate collected answers into the engine's documented env vars.

    Returns a dict of ONLY the vars we set; the caller merges it over
    os.environ for the subprocess. Secrets are included here (for the run's
    env) but are never persisted — see config.SECRET_KEYS.
    """
    env: dict[str, str] = {"WIZARD": "1"}

    # Required gateway contract.
    if answers.get("_gateway_url"):
        env["LITELLM_URL"] = str(answers["_gateway_url"])
    if answers.get("_master_key"):
        env["LITELLM_MASTER_KEY"] = str(answers["_master_key"])

    # Region + discovery profile.
    if answers.get("region"):
        env["REGION"] = str(answers["region"])
    if answers.get("aws_profile"):
        env["AWS_PROFILE"] = str(answers["aws_profile"])

    # Model families → WIZARD_DELETE_SCOPE, validated fail-closed against
    # {claude, mantle, both} (register-models.sh:248). NOTE: this is the
    # family axis. It is NOT the same as the engine's SCOPE var, which is the
    # inference-profile region axis {us, global, both} and is left at its
    # default here (the wizard v1 does not ask about region scope).
    env["WIZARD_DELETE_SCOPE"] = _FAMILY_TO_SCOPE.get(
        str(answers.get("families", "")), "both"
    )

    # Catalog mode → WIZARD_MODE, which the engine validates fail-closed
    # against exactly {additive, clean} (register-models.sh:247). "clean" =
    # delete-then-register the supported set; "additive" = register new only.
    mode = str(answers.get("catalog_mode", "clean")).lower()
    env["WIZARD_MODE"] = "additive" if mode.startswith(("add", "keep")) else "clean"

    # Optional include/exclude overrides.
    if answers.get("include"):
        env["WIZARD_INCLUDE"] = str(answers["include"])
    if answers.get("exclude"):
        env["WIZARD_EXCLUDE"] = str(answers["exclude"])

    # Optional cross-account discovery (advanced).
    for key, var in (
        ("tenant", "TENANT"),
        ("bedrock_role_arn", "BEDROCK_ROLE_ARN"),
        ("bedrock_external_id", "BEDROCK_EXTERNAL_ID"),
        ("discover_profile", "DISCOVER_PROFILE"),
    ):
        if answers.get(key):
            env[var] = str(answers[key])

    return env


def run(answers: dict, *, dry_run: bool, confirm: bool) -> int:
    """Run register-models.sh with the built env. Returns its exit code.

    dry_run=True  → DRY_RUN=1 (engine previews, mutates nothing).
    confirm=True  → WIZARD_CONFIRM=1 (engine's own confirm gate is satisfied;
                    used only after the operator approved the plain-language
                    plan). We pass through the engine's gate, we don't replace
                    it (spec §5.3, §10).
    """
    env = dict(os.environ)
    env.update(build_env(answers))
    if dry_run:
        env["DRY_RUN"] = "1"
    if confirm:
        env["WIZARD_CONFIRM"] = "1"

    # Flush our narration before the child inherits this fd, so the line we
    # just printed ("Updating the gateway's model catalog…") cannot be
    # overtaken by the engine's own output when stdout is a pipe (#107).
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except (ValueError, OSError):  # pragma: no cover - detached stream
            pass

    return subprocess.call(
        ["bash", str(REGISTER_SCRIPT)],
        cwd=str(DEPLOY_DIR),
        env=env,
    )
