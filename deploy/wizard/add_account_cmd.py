"""`tgw add-account` — onboard a second AWS account to an existing gateway.

Asks a few questions, then:
  1. Checks credentials for the target account.
  2. Mints a Bedrock bearer token (Mantle) from the target account.
  3. Injects the key into the running LiteLLM process via POST /config/update
     — no ECS restart needed; picks up within ~30s via the DB reload cycle.
  4. Runs register-models.sh with TENANT=<prefix> + the right WIZARD_FAMILY /
     BEDROCK_API_KEY_ENV — the same engine that handles the primary account,
     unchanged (#129 design: reuse the engine, never reimplement it).
  5. Creates a LiteLLM team + virtual key restricted to <prefix>/* models.
  6. Writes a Codex catalog sample to example/developer-setup/codex-setup/.
  7. Prints cron instructions for ongoing token refresh.

Design notes:
  * /config/update is an internal LiteLLM endpoint (include_in_schema=False in
    v1.92.0). It works but is not formally versioned — comment notes this.
  * Only Mantle (bearer-key) is supported for v1.  Bedrock-only / Both can be
    added later; the Questions list is already structured for it.
  * stdlib only (subprocess, urllib.request, json, base64) — no extra deps
    beyond boto3/botocore (already required by the refresh scripts).
"""
from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from . import config, engine, preflight, ui
from .prompts import PromptAbort, Question, Resolver

EXIT_OK = 0
EXIT_ABORT = 2
EXIT_ENGINE = 1
EXIT_INTERRUPT = 130

# Mantle model catalog — the full current set (#128).
MANTLE_MODELS = [
    "openai.gpt-5.6-sol",
    "openai.gpt-5.5",
    "openai.gpt-5.6-luna",
    "openai.gpt-5.6-terra",
]

FAMILIES = [
    "Mantle only  (OpenAI GPT models via Bedrock Mantle)",
]

# Where the Codex catalog sample is written (relative to deploy/).
DEPLOY_DIR = Path(__file__).resolve().parent.parent
CODEX_SETUP_DIR = DEPLOY_DIR.parent / "example" / "developer-setup" / "codex-setup"


# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------

def _questions() -> list[Question]:
    return [
        Question(
            key="account_prefix",
            prompt="Account prefix",
            why="namespaces all models + team for this account (e.g. 'demo0', 'teamA'). "
                "Operators use this prefix in virtual-key allowed-models lists.",
            default=None,
            validate=_valid_prefix,
        ),
        Question(
            key="families",
            prompt="What models does this account provide?",
            why="determines which discovery path to use and which key type to mint.",
            choices=FAMILIES,
            default=FAMILIES[0],
        ),
        Question(
            key="aws_profile",
            prompt="AWS profile for the new account",
            why="the named profile in ~/.aws/config that has credentials for the target "
                "account (the role that can call Bedrock + mint Mantle bearer tokens).",
            default=None,
        ),
    ]


def _valid_prefix(v: str) -> str | None:
    if not v:
        return "prefix cannot be empty."
    if not re.match(r"^[A-Za-z0-9_]+$", v):
        return "use letters, digits, or underscore only (no dashes — would create invalid shell var names)."
    return None


# ---------------------------------------------------------------------------
# Credential check for the target account
# ---------------------------------------------------------------------------

def _check_account_creds(profile: str, region: str) -> str:
    """Return the account ID or raise RuntimeError."""
    ident = preflight.aws_identity(profile, region)
    if "error" in ident:
        raise RuntimeError(
            f"credentials for profile '{profile}' failed: {ident['error']}\n"
            f"    → {preflight.sso_login_hint(profile)}"
        )
    return ident["account"]


# ---------------------------------------------------------------------------
# Mantle token minting (reuses the same algorithm as refresh-mantle-account.py)
# ---------------------------------------------------------------------------

def _mint_mantle_token(profile: str, region: str) -> str:
    """Mint a Bedrock bearer token from the target account via AWS profile."""
    try:
        import boto3
        from botocore.auth import SigV4QueryAuth
        from botocore.awsrequest import AWSRequest
    except ImportError:
        raise RuntimeError("boto3 and botocore are required — install them and re-run.")

    session = boto3.Session(profile_name=profile, region_name=region)
    creds = session.get_credentials()
    if creds is None:
        raise RuntimeError(f"no credentials found for profile '{profile}'.")
    frozen = creds.get_frozen_credentials()

    host = "bedrock.amazonaws.com"
    url = f"https://{host}/"
    req = AWSRequest(method="POST", url=url, headers={"host": host},
                     params={"Action": "CallWithBearerToken"})
    SigV4QueryAuth(frozen, "bedrock", region, expires=43200).add_auth(req)
    token = "bedrock-api-key-" + base64.b64encode(
        (req.url.replace("https://", "") + "&Version=1").encode()
    ).decode()
    return token


# ---------------------------------------------------------------------------
# LiteLLM API helpers (stdlib urllib only)
# ---------------------------------------------------------------------------

def _api(gateway_url: str, master_key: str, path: str, body: dict) -> dict:
    """POST to the LiteLLM admin API. Returns parsed JSON or raises RuntimeError."""
    url = gateway_url.rstrip("/") + "/" + path.lstrip("/")
    data = json.dumps(body).encode()
    # Secret-safe: key goes in the Authorization header, not the URL.
    req = urllib.request.Request(
        url, data=data,
        headers={
            "Authorization": f"Bearer {master_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        # Do NOT echo the response body — it may contain an auth-token echo.
        raise RuntimeError(f"HTTP {e.code} from {path} (response body redacted)")
    except urllib.error.URLError as e:
        raise RuntimeError(f"could not reach {url}: {e.reason}")


def _inject_env_var(gateway_url: str, master_key: str, key_name: str, value: str) -> None:
    """Inject a single env var into the running LiteLLM process via /config/update.

    /config/update is an internal LiteLLM endpoint (include_in_schema=False in
    v1.92.0 — not formally versioned). Values land in os.environ within one
    reload cycle (~30s default) and are then resolvable as os.environ/<KEY> in
    litellm_params at request time, with no ECS restart required.
    """
    _api(gateway_url, master_key, "/config/update",
         {"environment_variables": {key_name: value}})


def _create_team(gateway_url: str, master_key: str, team_alias: str,
                 allowed_models: list[str]) -> str:
    """Create a LiteLLM team restricted to the given models. Returns team_id."""
    resp = _api(gateway_url, master_key, "/team/new", {
        "team_alias": team_alias,
        "models": allowed_models,
    })
    tid = resp.get("team_id", "")
    if not tid:
        raise RuntimeError(
            f"team creation returned no team_id: {str(resp)[:200]}"
        )
    return tid


def _generate_key(gateway_url: str, master_key: str, team_id: str,
                  key_alias: str, allowed_models: list[str]) -> str:
    """Generate a virtual key for the team. Returns the key string."""
    resp = _api(gateway_url, master_key, "/key/generate", {
        "team_id": team_id,
        "key_alias": key_alias,
        "models": allowed_models,
    })
    key = resp.get("key", "")
    if not key:
        raise RuntimeError(
            f"key generation returned no key: {str(resp)[:200]}"
        )
    return key


# ---------------------------------------------------------------------------
# Codex catalog + config
# ---------------------------------------------------------------------------

_REASONING_LEVELS = [
    {"effort": "low",      "description": "Fast responses with lighter reasoning"},
    {"effort": "medium",   "description": "Standard reasoning"},
    {"effort": "high",     "description": "Deeper reasoning — slower"},
    {"effort": "highest",  "description": "Maximum reasoning quality"},
]


def _catalog_entry(prefix: str, model_name: str) -> dict:
    """Build a minimal but Codex-loadable ModelInfo entry.

    All fields required by `codex debug models` validation are present.
    `base_instructions` and `model_messages.instructions_template` are
    included as empty strings — the gateway does not fabricate model-specific
    system prompts, but the fields must exist for Codex schema validation.
    """
    slug = f"{prefix}/{model_name}"
    return {
        "slug": slug,
        "display_name": model_name,
        "description": f"{model_name} via {prefix} Mantle account",
        "default_reasoning_level": "low",
        "supported_reasoning_levels": _REASONING_LEVELS,
        "shell_type": "shell_command",
        "visibility": "list",
        "supported_in_api": True,
        "priority": 1,
        "additional_speed_tiers": ["fast"],
        "service_tiers": [],
        "availability_nux": None,
        "upgrade": None,
        "include_skills_usage_instructions": False,
        "default_reasoning_summary": "none",
        "support_verbosity": True,
        "default_verbosity": "low",
        "apply_patch_tool_type": "freeform",
        "truncation_policy": {"mode": "tokens", "limit": 10000},
        "supports_parallel_tool_calls": True,
        "supports_image_detail_original": False,
        "context_window": 128000,
        "max_context_window": 128000,
        "comp_hash": "3000",
        "effective_context_window_percent": 95,
        "input_modalities": ["text"],
        "supports_search_tool": False,
        "use_responses_lite": False,
        "multi_agent_version": "v2",
        "tool_mode": None,
        "experimental_supported_tools": [],
        "base_instructions": "",
        "model_messages": {
            "instructions_template": "",
            "instructions_variables": {},
            "approvals": None,
            "auto_review": None,
            "permissions": None,
        },
    }


def _write_codex_catalog(prefix: str, model_names: list[str]) -> Path:
    """Write example/developer-setup/codex-setup/<prefix>-models.json.

    Format matches Codex ModelInfo: {"models": [{slug, display_name, ...}]}.
    """
    catalog = {"models": [_catalog_entry(prefix, m) for m in model_names]}
    CODEX_SETUP_DIR.mkdir(parents=True, exist_ok=True)
    path = CODEX_SETUP_DIR / f"{prefix}-models.json"
    path.write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")
    return path


def _write_codex_config(prefix: str, gateway_url: str) -> Path:
    """Write example/developer-setup/codex-setup/<prefix>.config.toml.

    Uses the lg-<gateway>-mantle-on-<prefix> naming convention with auth.command
    so the generated file matches the documented convention and the checked-in example.
    Gateway label is derived from the hostname (first DNS label, stripped of port).
    """
    hostname = gateway_url.rstrip("/").split("//")[-1].split("/")[0].split(":")[0]
    gateway_label = hostname.split(".")[0]
    provider = f"lg-{gateway_label}-mantle-on-{prefix}"
    key_file = f"$HOME/.codex/secrets/{provider}-litellm-key"
    content = (
        f'model_provider = "{provider}"\n'
        f'model = "{prefix}/openai.gpt-5.6-sol"\n'
        f'model_catalog_json = "$HOME/.codex/model-catalogs/{provider}.json"\n'
        f'web_search = "disabled"\n'
        f'model_reasoning_effort = "medium"\n'
        f'\n'
        f'[model_providers.{provider}]\n'
        f'name = "{prefix} Mantle models via LiteLLM gateway"\n'
        f'base_url = "{gateway_url.rstrip("/")}/v1"\n'
        f'wire_api = "responses"\n'
        f'\n'
        f'[model_providers.{provider}.auth]\n'
        f'command = "/usr/bin/cat"\n'
        f'args = ["{key_file}"]\n'
        f'timeout_ms = 1000\n'
        f'refresh_interval_ms = 0\n'
    )
    CODEX_SETUP_DIR.mkdir(parents=True, exist_ok=True)
    path = CODEX_SETUP_DIR / f"{prefix}.config.toml"
    path.write_text(content, encoding="utf-8")
    return path


# ---------------------------------------------------------------------------
# Cron instructions
# ---------------------------------------------------------------------------

def _print_cron_instructions(prefix: str, gateway_url: str) -> None:
    hostname = gateway_url.rstrip("/").split("//")[-1].split("/")[0].split(":")[0]
    gateway_label = hostname.split(".")[0]
    provider = f"lg-{gateway_label}-mantle-on-{prefix}"
    print()
    print("  Next steps:")
    print()
    print(f"  1. Create the Secrets Manager secret for the {prefix} token in the GATEWAY account:")
    print(f"       AWS_PROFILE=<gateway-account-profile> \\")
    print(f"       aws secretsmanager create-secret \\")
    print(f"         --region <gateway-region> \\")
    print(f"         --name BEDROCK_API_KEY_{prefix.upper()} \\")
    print(f"         --description '{prefix} Bedrock bearer key (rotated by cron)' \\")
    print(f"         --secret-string placeholder")
    print(f"       # (tgw add-account injects the initial token into the gateway only;")
    print(f"       #  the cron refresh writes to this secret via PutSecretValue)")
    print()
    print(f"  2. Give the developer the virtual key — store it at:")
    print(f"       mkdir -p $HOME/.codex/secrets && chmod 700 $HOME/.codex/secrets")
    print(f"       echo '<virtual-key>' > $HOME/.codex/secrets/{provider}-litellm-key")
    print(f"       chmod 600 $HOME/.codex/secrets/{provider}-litellm-key")
    print()
    print(f"  3. Cron refresh — add these two lines to your crontab (`crontab -e`):")
    print()
    print(f"       # {prefix} token (secondary account — runs first, skips ECS restart)")
    print(f"       0 */6 * * *   $HOME/.tg-litellm/refresh-mantle-account.sh"
          f"  >> $HOME/.tg-litellm/refresh-{prefix}.log 2>&1")
    print()
    print(f"       # primary account token + ECS restart (runs last, ~3 min after the above)")
    print(f"       3 */6 * * *   $HOME/.tg-litellm/refresh-codex-key.sh"
          f"  >> $HOME/.tg-litellm/refresh.log 2>&1")
    print()
    print(f"  4. Copy refresher scripts (skip if already installed) and set up venv:")
    print(f"       cp deploy/codex-key-refresher/refresh-mantle-account.sh $HOME/.tg-litellm/")
    print(f"       cp deploy/codex-key-refresher/refresh-mantle-account.py $HOME/.tg-litellm/")
    print(f"       chmod 700 $HOME/.tg-litellm/refresh-mantle-account.sh")
    print(f"       /usr/bin/python3 -m venv $HOME/.tg-litellm/venv  # if not already created")
    print(f"       $HOME/.tg-litellm/venv/bin/python3 -m pip install --quiet boto3 botocore")
    print(f"       # Create per-prefix env file:")
    print(f"       cp deploy/codex-key-refresher/refresh-mantle-account.env.sample \\")
    print(f"          $HOME/.tg-litellm/refresh-{prefix}-mantle-account.env")
    print(f"       chmod 600 $HOME/.tg-litellm/refresh-{prefix}-mantle-account.env")
    print(f"       # Edit it: CRED_MODE=profile, AWS_PROFILE={prefix}-<your-profile>,")
    print(f"       #          UPDATE_ECS=false,")
    print(f"       #          SECRET_ARN=<arn-of-BEDROCK_API_KEY_{prefix.upper()}-secret>")
    print()
    print(f"  See docs/codex-cron-key-refresh.md §6a for the full cron setup guide.")


# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

def run(args) -> int:
    """Entry point for the `add-account` subcommand."""
    supplied = _frozen_supplied(args)
    interactive = not args.non_interactive
    resolver = Resolver(
        interactive=interactive,
        supplied=supplied,
        scripted=getattr(args, "_scripted", None),
    )

    # Preflight: gateway vars must be supplied for this subcommand — there's no
    # discover step that can defer them.
    pf_url = supplied.get("LITELLM_URL")
    pf_key = supplied.get("LITELLM_MASTER_KEY")
    if not pf_url or not pf_key:
        ui.fail(
            "LITELLM_URL and LITELLM_MASTER_KEY must be set.",
            "export LITELLM_URL=https://<gateway> and export LITELLM_MASTER_KEY=sk-<key>, "
            "then re-run.",
            rerun_safe=True,
        )
        return EXIT_ABORT

    gateway_url = str(pf_url)
    master_key = str(pf_key)

    # Validate TGW_INJECT_WAIT early — before any mutations — so a bad value
    # doesn't leave a partially-applied onboarding (injected key, no sleep).
    _raw_wait = os.environ.get("TGW_INJECT_WAIT", "35")
    try:
        inject_wait = int(_raw_wait)
        if inject_wait < 0:
            raise ValueError("must be non-negative")
    except ValueError as e:
        ui.fail(
            f"TGW_INJECT_WAIT='{_raw_wait}' is not a valid number of seconds: {e}",
            "set TGW_INJECT_WAIT to a non-negative integer (e.g. 35) and re-run.",
            rerun_safe=True,
        )
        return EXIT_ABORT

    # --- Questions --------------------------------------------------------
    answers: dict = {}
    try:
        for q in _questions():
            answers[q.key] = resolver.ask(q)
    except PromptAbort as e:
        if str(e) == "interrupted":
            print("\n  Interrupted — re-run to start over.", file=sys.stderr)
            return EXIT_INTERRUPT
        ui.fail(str(e), "set the missing value and re-run.", rerun_safe=True)
        return EXIT_ABORT

    prefix = answers["account_prefix"].lower()
    profile = answers["aws_profile"]
    region = str(supplied.get("region", "us-east-1"))
    family_choice = answers["families"]

    # Map family choice to WIZARD_FAMILY engine value (v1 = Mantle-only).
    wizard_family = "mantle"

    # The env var name under which the bearer key lives in LiteLLM.
    bearer_key_var = f"BEDROCK_API_KEY_{prefix.upper()}"

    # --- Step 1: check credentials for the target account ----------------
    print(f"\n  Checking credentials for profile '{profile}'…", flush=True)
    try:
        account_id = _check_account_creds(profile, region)
        print(f"  ✓ account {account_id}")
    except RuntimeError as e:
        ui.fail(str(e), "fix the profile credentials and re-run.", rerun_safe=True)
        return EXIT_ABORT

    # --- Step 2: mint Mantle bearer token (Mantle) — skipped in dry-run ---
    bearer_token = None
    if wizard_family in ("mantle", "both") and not args.dry_run:
        print(f"\n  Minting Bedrock bearer token from account {account_id}…", flush=True)
        try:
            bearer_token = _mint_mantle_token(profile, region)
            print(f"  ✓ token minted (12h TTL)")
        except RuntimeError as e:
            ui.fail(str(e), "check Bedrock permissions for the profile and re-run.",
                    rerun_safe=True)
            return EXIT_ABORT

        # --- Step 3: inject via /config/update ---------------------------
        print(f"\n  Injecting {bearer_key_var} via /config/update…", flush=True)
        try:
            _inject_env_var(gateway_url, master_key, bearer_key_var, bearer_token)
            print(f"  ✓ {bearer_key_var} injected — live in ~30s (no ECS restart)")
        except RuntimeError as e:
            ui.fail(str(e),
                    "check LITELLM_URL and LITELLM_MASTER_KEY are correct and re-run.",
                    rerun_safe=True)
            return EXIT_ABORT

        print(f"  Waiting {inject_wait}s for the gateway to pick up the new key…", flush=True)
        time.sleep(inject_wait)

    # --- Step 4: register models (reuse register-models.sh engine) -------
    print(f"\n  Registering {prefix}/* models on the gateway…", flush=True)
    engine_answers = {
        "_gateway_url": gateway_url,
        "_master_key": master_key,
        "region": region,
        "aws_profile": profile,
        "families": "OpenAI/Mantle only",
        "catalog_mode": "Clean — reset",
        # TENANT causes register-models.sh to namespace all models under prefix/.
        "tenant": prefix,
        # Tell the engine which env var holds this account's bearer key.
        "bedrock_api_key_env": bearer_key_var,
    }
    rc = engine.run(engine_answers, dry_run=args.dry_run, confirm=True)
    if rc != 0:
        ui.fail(
            "model registration reported an error.",
            "review the output above; re-running is safe (it's idempotent).",
            rerun_safe=True,
        )
        return EXIT_ENGINE

    if args.dry_run:
        print("\n  (dry-run) — no team/key/catalog created. Re-run without --dry-run to apply.")
        return EXIT_OK

    # --- Step 5: create team + virtual key --------------------------------
    team_alias = f"{prefix}-team"
    key_alias = f"{prefix}-key"
    # Wildcard covers all models registered under this prefix, avoiding allowlist drift.
    allowed = [f"{prefix}/*"]

    print(f"\n  Creating team '{team_alias}'…", flush=True)
    try:
        team_id = _create_team(gateway_url, master_key, team_alias, allowed)
        print(f"  ✓ team created ({team_id})")
    except RuntimeError as e:
        ui.fail(str(e), "check the gateway is reachable and re-run.", rerun_safe=True)
        return EXIT_ABORT

    print(f"  Generating virtual key for '{team_alias}'…", flush=True)
    try:
        virtual_key = _generate_key(gateway_url, master_key, team_id, key_alias, allowed)
        print(f"  ✓ virtual key generated")
    except RuntimeError as e:
        ui.fail(str(e), "check the gateway is reachable and re-run.", rerun_safe=True)
        return EXIT_ABORT

    # --- Step 6: write Codex catalog + config ----------------------------
    catalog_path = _write_codex_catalog(prefix, MANTLE_MODELS)
    config_path = _write_codex_config(prefix, gateway_url)
    print(f"\n  ✓ Codex catalog  → {catalog_path.relative_to(DEPLOY_DIR.parent)}")
    print(f"  ✓ Codex config   → {config_path.relative_to(DEPLOY_DIR.parent)}")

    # --- Done banner ------------------------------------------------------
    print()
    print(f"  ✓ Done — {prefix} account onboarded.")
    print()
    print(f"  Virtual key (store securely — not logged by this command again):")
    print(f"    {virtual_key}")
    print()
    print(f"  Key restricts to {prefix}/* only — operators cannot reach other accounts' models.")

    _print_cron_instructions(prefix, gateway_url)

    return EXIT_OK


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _frozen_supplied(args) -> dict:
    supplied: dict = {}
    for ans_key, env_var in (
        ("region", "REGION"),
        ("aws_profile", "AWS_PROFILE"),
        ("account_prefix", "ACCOUNT_PREFIX"),
    ):
        v = os.environ.get(env_var)
        if v:
            supplied[ans_key] = v
    for passthru in ("LITELLM_URL", "LITELLM_MASTER_KEY"):
        v = os.environ.get(passthru)
        if v:
            supplied[passthru] = v
    return supplied
