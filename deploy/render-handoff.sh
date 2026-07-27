#!/usr/bin/env bash
# Render a complete, copy-ready developer configuration package (#40/#41).
#
#   AWS_PROFILE=<profile> ./render-handoff.sh <env> <claude|codex> <key_alias> \
#       [--create BUDGET_USD MODEL[,MODEL...]] [--key-file PATH]
#
# The ADMIN runs this to hand a developer a complete package they paste verbatim
# (no developer curl / model discovery / TOML authoring / catalog generation).
#
# Getting the developer's virtual key value (fixes #43): LiteLLM only returns a
# key's secret at CREATION time — it cannot be recovered from a later
# /key/info?key_alias= lookup. So this script either:
#   * --create BUDGET MODELS : creates the key HERE and captures the one-time
#     secret from the creation response (single create-to-render flow), or
#   * --key-file PATH        : reads the one-time secret from an owner-only file
#     the admin saved at creation time (stdin also accepted: --key-file -).
# The raw key is NEVER passed on argv, and all gateway calls authenticate via a
# curl --config file (owner-only, removed on exit) so no key/master-key appears in
# the process table (fixes #50). The allowlist is read from /key/info metadata
# (non-secret) — only the secret VALUE needs the creation/file path.
#
# Security: the rendered OUTPUT contains the developer's key (it must, to be
# usable) — deliver only through the approved secure channel. This script holds no
# secrets and is safe to publish.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
. ./lib.sh

ENV="${1:-}"; KIND="${2:-}"; KEY_ALIAS="${3:-}"; shift 3 2>/dev/null || true
CREATE=0; CREATE_BUDGET=""; CREATE_MODELS=""; KEY_FILE=""; MODELS_ARG=""
USER_ID=""; TEAM_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --create) CREATE=1; CREATE_BUDGET="${2:-}"; CREATE_MODELS="${3:-}"; shift 3 ;;
    --key-file) KEY_FILE="${2:-}"; shift 2 ;;
    --models) MODELS_ARG="${2:-}"; shift 2 ;;
    --user) USER_ID="${2:-}"; shift 2 ;;
    --team) TEAM_ID="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
  esac
done
[ -n "$ENV" ] && [ -n "$KIND" ] && [ -n "$KEY_ALIAS" ] || {
  echo "usage: AWS_PROFILE=<profile> ./render-handoff.sh <env> <claude|codex> <key_alias> [--create BUDGET_USD MODELS] [--key-file PATH] [--user USER_ID] [--team TEAM_ID]" >&2; exit 1; }

HANDOFF="handoff.${ENV}.json"
[ -f "$HANDOFF" ] || { echo "ERROR: $HANDOFF not found — run './deploy.sh $ENV install' first." >&2; exit 1; }

j() { python3 -c "import json,sys;print(json.load(open('$HANDOFF'))$1)"; }
GW="$(j "['gateway_url']")"
MK_ARN="$(j "['secret_references']['master_key_secret_arn']")"
CLAUDE_VER="$(j "['supported_client_versions']['claude_code']")"
CODEX_VER="$(j "['supported_client_versions']['codex']")"
[ -n "$GW" ] || { echo "ERROR: gateway_url missing from $HANDOFF" >&2; exit 1; }

# --- secret-safe curl: master key goes in an owner-only --config file, not argv (#50) ---
CURL_CFG="$(mktemp)"; chmod 600 "$CURL_CFG"
trap 'rm -f "$CURL_CFG" "${VKEY_TMP:-}"' EXIT
MK="$(aws secretsmanager get-secret-value --secret-id "$MK_ARN" --query SecretString --output text 2>/dev/null || true)"
[ -n "$MK" ] || { echo "ERROR: could not read master key from $MK_ARN (need admin AWS creds)." >&2; exit 1; }
printf 'header = "Authorization: Bearer %s"\n' "$MK" > "$CURL_CFG"
gwcurl() { curl -s -m 30 --config "$CURL_CFG" "$@"; }   # key never on argv

# Serving registry (#45): the exact model ids the gateway actually serves via
# /v1/models. A key allowlist can name a model the gateway does NOT serve (the
# fresh-account trap: only global/… + us/… are registered, no bare claude-*), and
# such a request fails at the gateway with HTTP 400 even though key policy allows
# it. So --create validates requested models against THIS set before minting a key.
SERVED_IDS="$(gwcurl "$GW/v1/models" | python3 -c "import sys,json;print('\n'.join(m['id'] for m in json.load(sys.stdin).get('data',[])))" 2>/dev/null || true)"
is_served() { printf '%s\n' "$SERVED_IDS" | grep -qxF "$1"; }

# --- obtain the developer key VALUE (fix #43) ---
VKEY=""
if [ "$CREATE" = 1 ]; then
  [ -n "$CREATE_BUDGET" ] && [ -n "$CREATE_MODELS" ] || { echo "ERROR: --create needs BUDGET_USD and MODELS" >&2; exit 1; }
  # Validate requested models against the SERVING registry BEFORE minting a key
  # (#45). Creating a key whose allowlist names an unserved model yields a working
  # key that fails at request time with gateway HTTP 400 — the fresh-account trap.
  # Fail closed with an actionable message listing what IS served for this client.
  if [ -n "$SERVED_IDS" ]; then
    missing=""
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      is_served "$m" || missing="${missing:+$missing, }$m"
    done <<< "$(printf '%s' "$CREATE_MODELS" | tr ',' '\n')"
    if [ -n "$missing" ]; then
      echo "ERROR(#45): requested model(s) not served by the gateway: $missing" >&2
      case "$KIND" in
        claude) echo "  Served client-compatible (non-slash) Claude aliases:" >&2
                printf '%s\n' "$SERVED_IDS" | grep -E 'claude' | grep -vE '/' | sed 's/^/    /' >&2
                echo "  (slash/scope aliases like global/… are served but rejected by Claude Code; pick a bare one.)" >&2 ;;
        codex)  echo "  Served Codex (gpt-5.x) models:" >&2
                printf '%s\n' "$SERVED_IDS" | grep -E 'gpt-5' | sed 's/^/    /' >&2 ;;
      esac
      exit 1
    fi
  else
    echo "NOTE(#45): could not read /v1/models to pre-validate requested models; proceeding (renderer still fails closed later if no client-compatible alias is served)." >&2
  fi
  # Ownership (#55): a key with user_id=null makes package-driven spend
  # unattributable and defeats per-user budgets / cross-user isolation. Attach an
  # owner. Use --user if given; otherwise DERIVE a documented, safe identity from
  # the key alias so the recommended `--create` flow is owned by default (never
  # silently ownerless). Ensure the user row exists first (idempotent: a
  # "already exists" is fine), so /key/generate attaches to a real user.
  OWNER_USER="${USER_ID:-$KEY_ALIAS}"
  UBODY="$(python3 -c "import json,sys;print(json.dumps({'user_id':sys.argv[1],'user_role':'internal_user','auto_create_key':False}))" "$OWNER_USER")"
  URESP="$(gwcurl "$GW/user/new" -H "Content-Type: application/json" -d "$UBODY" 2>/dev/null || true)"
  if printf '%s' "$URESP" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get('error') and 'exist' not in json.dumps(d).lower() else 1)" 2>/dev/null; then
    echo "   NOTE(#55): /user/new for '$OWNER_USER' returned an error; continuing (user may already exist): $(printf '%s' "$URESP" | head -c 120)" >&2
  fi
  # Validate the team EXISTS before attaching (#55). Unlike a user (which we
  # auto-create above), a team is an authorization/governance boundary the admin
  # creates deliberately with its own model allowlist + budget — so we must NOT
  # invent one. LiteLLM's /key/generate happily accepts an arbitrary team_id and
  # renders a key carrying a nonexistent team, which defeats team-boundary
  # governance. Verify via /team/info and FAIL CLOSED if it doesn't resolve.
  if [ -n "$TEAM_ID" ]; then
    TRESP="$(gwcurl "$GW/team/info?team_id=$TEAM_ID" 2>/dev/null || true)"
    if ! printf '%s' "$TRESP" | TEAM_ID="$TEAM_ID" python3 -c "
import sys,os,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
if d.get('error'): sys.exit(1)
info=d.get('team_info') or d.get('info') or d
tid=info.get('team_id') if isinstance(info,dict) else None
sys.exit(0 if tid==os.environ['TEAM_ID'] else 1)" 2>/dev/null; then
      echo "ERROR(#55): team '$TEAM_ID' does not exist (or is not authorized). Create it first (see docs/admin.md 'Teams'), then re-render. Not attaching a key to a nonexistent team." >&2
      exit 1
    fi
    echo "   team '$TEAM_ID' validated (exists) (#55)" >&2
  fi
  # Create the key HERE (owned by OWNER_USER, and TEAM_ID if given) and capture the
  # one-time secret from the creation response.
  MODELS_JSON="$(python3 -c "import json,sys;print(json.dumps(sys.argv[1].split(',')))" "$CREATE_MODELS")"
  BODY="$(OWNER_USER="$OWNER_USER" TEAM_ID="$TEAM_ID" python3 -c "
import json,os,sys
b={'key_alias':sys.argv[1],'max_budget':float(sys.argv[2]),'budget_duration':'30d','models':json.loads(sys.argv[3]),'user_id':os.environ['OWNER_USER']}
if os.environ.get('TEAM_ID'): b['team_id']=os.environ['TEAM_ID']
print(json.dumps(b))" "$KEY_ALIAS" "$CREATE_BUDGET" "$MODELS_JSON")"
  RESP="$(gwcurl "$GW/key/generate" -H "Content-Type: application/json" -d "$BODY")"
  VKEY="$(printf '%s' "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('key',''))" 2>/dev/null || true)"
  [ -n "$VKEY" ] || { echo "ERROR: key creation failed: $(printf '%s' "$RESP" | head -c 160)" >&2; exit 1; }
  # Confirm ownership actually took (#55): a key that came back with user_id=null
  # would be unattributable — fail closed rather than hand out an ownerless key.
  GOT_USER="$(printf '%s' "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('user_id') or '')" 2>/dev/null || true)"
  if [ -z "$GOT_USER" ]; then
    echo "ERROR(#55): created key has no user_id (ownership did not attach). Not rendering an unattributable key." >&2
    exit 1
  fi
  echo "   key owned by user '$GOT_USER'${TEAM_ID:+, team '$TEAM_ID'} (spend is attributable) (#55)" >&2
  # Allowlist is authoritative from the create args (do NOT depend on a later
  # /key/info alias query — it 404s in some deployments, #43).
  RESP_MODELS="$(printf '%s' "$RESP" | python3 -c "import sys,json;print('\n'.join(json.load(sys.stdin).get('models',[]) or []))" 2>/dev/null || true)"
  ALLOWED="${RESP_MODELS:-$(printf '%s' "$CREATE_MODELS" | tr ',' '\n')}"
elif [ -n "$KEY_FILE" ]; then
  if [ "$KEY_FILE" = "-" ]; then IFS= read -r VKEY || true; else   # read returns 1 at EOF (no trailing newline) — not an error here
    [ -f "$KEY_FILE" ] || { echo "ERROR: --key-file '$KEY_FILE' not found" >&2; exit 1; }
    VKEY="$(cat "$KEY_FILE")"
  fi
  VKEY="${VKEY//[$'\r\n\t ']/}"
  [ -n "$VKEY" ] || { echo "ERROR: --key-file was empty" >&2; exit 1; }
  # In key-file mode the allowlist comes from --models (authoritative, no alias
  # query). Fall back to a best-effort /key/info only if --models is omitted.
  if [ -n "$MODELS_ARG" ]; then
    ALLOWED="$(printf '%s' "$MODELS_ARG" | tr ',' '\n')"
  fi
else
  cat >&2 <<MSG
ERROR: no key source. LiteLLM only returns a virtual key's secret at CREATION —
it cannot be recovered from a later alias lookup (#43). Either:
  --create <BUDGET_USD> <MODEL[,MODEL...]>   create the key now and render it, or
  --key-file <PATH>                          read the one-time secret saved at creation (or '-' for stdin)
MSG
  exit 1
fi

# Allowlist resolution (#43): prefer the authoritative source set above (create
# response / --models). Only as a LAST resort try /key/info by alias, which 404s
# in some deployments — a failure here must not abort when we already have models.
ALLOWED="${ALLOWED:-}"
if [ -z "$ALLOWED" ]; then
  ALLOWED="$(gwcurl "$GW/key/info?key_alias=$KEY_ALIAS" | python3 -c "import sys,json;d=json.load(sys.stdin);print('\n'.join(d.get('info',{}).get('models',[]) or []))" 2>/dev/null || true)"
fi
if [ -z "$ALLOWED" ]; then
  echo "ERROR(#43): no model allowlist available. In --key-file mode pass --models MODEL[,MODEL...] (the key's allowed models); the /key/info alias lookup is unavailable in this deployment." >&2
  exit 1
fi

# Write the key to an owner-only temp for the heredocs to read (never on argv).
VKEY_TMP="$(mktemp)"; chmod 600 "$VKEY_TMP"; printf '%s' "$VKEY" > "$VKEY_TMP"

case "$KIND" in
claude)
  # Fix #45: Claude Code rejects slash/scope aliases (global/, us/). Select a
  # CLIENT-COMPATIBLE alias: a bare (non-slash) claude-* id that is ALSO actually
  # served by the gateway. Filtering by SERVED_IDS (when available) closes the
  # fresh-account trap where the allowlist names a bare alias the gateway doesn't
  # serve — that would render a package whose real CLI request 400s.
  claude_candidates() { printf '%s\n' "$ALLOWED" | grep -E 'claude' | grep -vE '/'; }
  served_claude() {
    if [ -n "$SERVED_IDS" ]; then
      while IFS= read -r m; do [ -n "$m" ] && is_served "$m" && printf '%s\n' "$m"; done < <(claude_candidates)
    else
      claude_candidates
    fi
  }
  PRIMARY="$(served_claude | grep -m1 . || true)"
  FAST="$(served_claude | grep -m1 -iE 'haiku|fast' || echo "$PRIMARY")"
  if [ -z "$PRIMARY" ]; then
    if [ -n "$SERVED_IDS" ] && claude_candidates | grep -q .; then
      echo "ERROR(#45): key '$KEY_ALIAS' allows bare Claude alias(es) but the gateway does not SERVE them. Register a client-compatible alias (register-models.sh now adds bare 'claude-*' names) and re-render. Served bare Claude aliases:" >&2
      printf '%s\n' "$SERVED_IDS" | grep -E 'claude' | grep -vE '/' | sed 's/^/    /' >&2
    else
      echo "ERROR(#45): key '$KEY_ALIAS' allows only slash/scope Claude aliases (global/… or us/…), which the Claude Code CLI rejects. Add a bare 'claude-*' client alias to the key's allowlist and re-render." >&2
    fi
    exit 1
  fi
  cat <<PKG
# ===== Claude Code package — environment: $ENV (paste verbatim) =====
# Supported Claude Code version: $CLAUDE_VER  (pinned; used by the container fallback)
export LG_ENV="$ENV"
export LG_CLAUDE_VERSION="$CLAUDE_VER"
mkdir -p "\$HOME/.claude-lg-$ENV" && chmod 700 "\$HOME/.claude-lg-$ENV"
umask 077
cat > "\$HOME/.claude-lg-$ENV/settings.json" <<'JSON'
{
  "env": {
    "ANTHROPIC_BASE_URL": "$GW",
    "ANTHROPIC_AUTH_TOKEN": "$(cat "$VKEY_TMP")",
    "ANTHROPIC_MODEL": "$PRIMARY",
    "ANTHROPIC_SMALL_FAST_MODEL": "$FAST"
  },
  "permissions": { "defaultMode": "default" }
}
JSON
chmod 600 "\$HOME/.claude-lg-$ENV/settings.json"
# Launcher (fix #47): run through a SCRUBBED provider environment so an inherited
# CLAUDE_CODE_USE_BEDROCK / _VERTEX / ANTHROPIC_API_KEY can't bypass the gateway.
# Fail closed if a conflicting selector is still set after scrubbing.
grep -q "claude-lg-$ENV()" "\$HOME/.bash_profile" 2>/dev/null || cat >> "\$HOME/.bash_profile" <<'PROFILE'
claude-lg-$ENV() {
  for v in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX ANTHROPIC_API_KEY AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
    if [ -n "\${!v:-}" ]; then echo "claude-lg-$ENV: refusing to launch — conflicting provider var \$v is set; open a clean shell" >&2; return 3; fi
  done
  env -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u ANTHROPIC_API_KEY \
      CLAUDE_CONFIG_DIR="\$HOME/.claude-lg-$ENV" claude "\$@"
}
PROFILE
# Managed-settings check (#39): INLINE detection — the package runs on the
# developer's host, which has no ./deploy/ script, so we must test the real files
# directly (a relative script call would be missing and false-positive). Only warn
# when a managed-settings file ACTUALLY exists. Container fallback pins the version
# (baked at render, #48 — the pasted command needs no host var).
_lg_managed=""
for _p in /etc/claude-code/managed-settings.json "\$HOME/Library/Application Support/ClaudeCode/managed-settings.json" "/Library/Application Support/ClaudeCode/managed-settings.json" "\$PROGRAMDATA/ClaudeCode/managed-settings.json"; do
  [ -f "\$_p" ] && _lg_managed="\$_p" && break
done
if [ -n "\$_lg_managed" ]; then
  echo "NOTE: managed Claude settings present (\$_lg_managed) — token auth won't work here; use the container fallback (pinned to $CLAUDE_VER):"
  echo "  docker run --rm -it -e CLAUDE_CONFIG_DIR=/cfg -v \"\$HOME/.claude-lg-$ENV:/cfg:ro\" -w /work -v \"\$PWD:/work\" node:22 bash -lc 'npm i -g @anthropic-ai/claude-code@$CLAUDE_VER && claude --version && claude'"
fi
unset _lg_managed _p
# Then:  source ~/.bash_profile && claude-lg-$ENV
# ===== end Claude Code package =====
PKG
  ;;
codex)
  DEFAULT="$(printf '%s\n' "$ALLOWED" | grep -m1 -E 'gpt-5' || true)"
  [ -n "$DEFAULT" ] || { echo "ERROR: key '$KEY_ALIAS' allows no Codex (gpt-5.x) model." >&2; exit 1; }
  # Fix #44: actually GENERATE the catalog here (version-matched) and embed it in
  # the package so it is self-contained. make-codex-catalog.sh needs the codex CLI;
  # if unavailable, fail closed rather than reference a file we never create.
  # Fix #44: generate a catalog covering EVERY allowlisted Codex model (not just
  # the default), then merge into one {"models":[…]} file. make-codex-catalog.sh
  # emits one {"models":[entry]} per model; we concatenate the entries.
  CODEX_MODELS="$(printf '%s\n' "$ALLOWED" | grep -E 'gpt-5' || true)"
  CATALOG=""
  if command -v codex >/dev/null 2>&1; then
    SRC_SLUG="$(codex debug models 2>/dev/null | python3 -c "import sys,json;print((json.load(sys.stdin).get('models') or [{}])[0].get('slug',''))" 2>/dev/null || true)"
    if [ -n "$SRC_SLUG" ]; then
      # Collect each per-model catalog doc into its own file, then merge with a
      # proper JSON parser (docs are multi-line/pretty-printed, so a line-by-line
      # merge is wrong — that was the R3 catalog bug the contract test caught).
      CATDIR="$(mktemp -d)"; i=0
      while IFS= read -r m; do
        [ -z "$m" ] && continue
        if ./make-codex-catalog.sh "$m" "$SRC_SLUG" > "$CATDIR/$i.json" 2>/dev/null; then :; fi
        i=$((i+1))
      done <<< "$CODEX_MODELS"
      CATALOG="$(CATDIR="$CATDIR" python3 -c "
import os,glob,json
models=[]
for f in sorted(glob.glob(os.path.join(os.environ['CATDIR'],'*.json'))):
    try:
        with open(f) as fh: models += json.load(fh).get('models',[])
    except Exception: pass
print(json.dumps({'models':models}, indent=2))" 2>/dev/null || true)"
      rm -rf "$CATDIR"
    fi
  fi
  # Fail closed unless the catalog actually covers every allowlisted Codex model.
  want="$(printf '%s\n' "$CODEX_MODELS" | grep -c .)"
  got="$(printf '%s' "$CATALOG" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('models',[])))" 2>/dev/null || echo 0)"
  if [ -z "$CATALOG" ] || [ "${got:-0}" -lt "${want:-1}" ]; then
    echo "ERROR(#44): could not build a complete version-matched Codex catalog ($got/$want models). Run render on a host with the supported 'codex' CLI installed." >&2
    exit 1
  fi
  # Derive the real supported Codex version from the CLI rather than a stale constant (#44).
  CODEX_REAL="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "$CODEX_VER")"
  cat <<PKG
# ===== Codex package — environment: $ENV (paste verbatim) =====
# Supported Codex version: $CODEX_REAL. Default model: $DEFAULT
# Allowed models for this key:
$(printf '%s\n' "$ALLOWED" | sed 's/^/#   /')
mkdir -p "\$HOME/.codex" && chmod 700 "\$HOME/.codex"
umask 077
# Version-matched catalog, generated by the admin and embedded here (self-contained):
cat > "\$HOME/.codex/$ENV-models.json" <<'CATALOG'
$CATALOG
CATALOG
cat > "\$HOME/.codex/$ENV.config.toml" <<TOML
model = "$DEFAULT"
model_provider = "litellm-gw"
model_catalog_json = "\$HOME/.codex/$ENV-models.json"
web_search = "disabled"

[model_providers.litellm-gw]
name = "LiteLLM Gateway"
base_url = "$GW/v1"
env_key = "LITELLM_KEY"
wire_api = "responses"
TOML
# Owner-only key file (sourced by the launcher), not committed:
printf 'export LITELLM_KEY=%s\n' "$(cat "$VKEY_TMP")" > "\$HOME/.codex/$ENV.key" && chmod 600 "\$HOME/.codex/$ENV.key"
# Launcher (fix #47): scrub provider env; fail closed on a conflicting selector.
grep -q "codex-lg-$ENV()" "\$HOME/.bash_profile" 2>/dev/null || cat >> "\$HOME/.bash_profile" <<'PROFILE'
codex-lg-$ENV() {
  for v in OPENAI_API_KEY AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
    if [ -n "\${!v:-}" ]; then echo "codex-lg-$ENV: refusing to launch — conflicting var \$v is set; open a clean shell" >&2; return 3; fi
  done
  . "\$HOME/.codex/$ENV.key"
  env -u OPENAI_API_KEY codex --profile $ENV "\$@"
}
PROFILE
# Start a FRESH session when switching envs.
# Then:  source ~/.bash_profile && codex-lg-$ENV
# ===== end Codex package =====
PKG
  ;;
*) echo "ERROR: kind must be 'claude' or 'codex' (got '$KIND')" >&2; exit 1 ;;
esac
