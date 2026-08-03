#!/usr/bin/env bash
# Discover Bedrock Claude + OpenAI/Mantle models and register them into a running
# LiteLLM gateway (Model Management).
#
# Portable: nothing is hardcoded to an account. Uses the active AWS_PROFILE,
# discovers models live and registers BOTH `global.` and `us.` Claude inference
# profiles under scope-prefixed names (global/<model>, us/<model> — no global-wins
# collapse; see #20), probes which Mantle (Responses-API) models are reachable,
# and registers everything via the LiteLLM admin API (/model/new).
#
# Usual use — one Bedrock account:
#   AWS_PROFILE=<profile> LITELLM_URL=http://<alb> LITELLM_MASTER_KEY=sk-... \
#   ./register-models.sh
#
# Advanced (optional) — register models against a DIFFERENT Bedrock account via
# cross-account AssumeRole (model names get a `<TENANT>/` prefix). For a
# cross-account run you MUST pass DISCOVER_PROFILE = credentials that can LIST
# models in the tenant account (there is NO built-in fallback model set):
#   TENANT=team-a BEDROCK_ROLE_ARN=arn:aws:iam::<ACCT>:role/litellm-bedrock \
#   BEDROCK_EXTERNAL_ID=<ext-id> DISCOVER_PROFILE=<tenant-lister-profile> \
#   AWS_PROFILE=<hub-profile> LITELLM_URL=... LITELLM_MASTER_KEY=... ./register-models.sh
#
# NOTE: registers models in the LiteLLM DB (persists, editable in the UI). Keep
# `proxy_config.model_list = []` in tfvars so the config file doesn't also define
# models — let THIS script be the single source of truth. Re-running is
# IDEMPOTENT: names already present are skipped (no duplicates). Delete stale
# ones in the UI or via /model/delete. Claude models register under BOTH
# `global/<model>` and `us/<model>` scope-prefixed names (not global-wins). (#20)
#
# Optional:
#   REGION=<region>                     (default: AWS_REGION, else us-east-1)
#   BEDROCK_API_KEY_ENV=BEDROCK_API_KEY (env var the gateway reads for Mantle auth)
#   DRY_RUN=1                           (print the model list, don't register)
#
# Wizard mode (#95) — opt-in, off by default; with WIZARD unset every line below
# is dead code and the script behaves byte-for-byte as before:
#   WIZARD=1                  turn on wizard mode (interactive if run at a TTY,
#                              env-driven otherwise). WIZARD=0/unset = today's
#                              purely-additive behavior, unchanged.
#   WIZARD_MODE=additive|clean   (default: clean) clean = delete-then-register;
#                              additive = register only, never delete.
#   WIZARD_DELETE_SCOPE=claude|mantle|both  (default: both) what to delete under
#                              WIZARD_MODE=clean, among the models THIS script
#                              registers. Names matching none of the script's own
#                              forms classify "other" and are left untouched — but
#                              that is incidental, not a protection guarantee: a
#                              row named exactly like one of our forms IS deleted
#                              (owner ownership model — see wizard_classify).
#   SCOPE=us|global|both       (default: both) which scope wins the bare/unscoped
#                              Claude alias (both = today's global-preferred, us
#                              fallback). Never narrows which scope-prefixed
#                              aliases (global/<model>, us/<model>) get registered
#                              — both are always registered; see #20.
#   WIZARD_INCLUDE / WIZARD_EXCLUDE   space-separated bare-model patterns (or
#                              "all") to include/exclude from registration;
#                              non-interactive analog of the review checklist.
#                              EXCLUDE wins over INCLUDE.
#   SKIP_DELETE=1              force-skip the delete phase even under
#                              WIZARD_MODE=clean.
#   WIZARD_CONFIRM=1           required (in addition to WIZARD=1) for a
#                              NON-interactive run that would MUTATE the gateway —
#                              i.e. any delete OR any register (clean, additive,
#                              and SKIP_DELETE alike). Not required at a TTY (the
#                              wizard asks directly) or under DRY_RUN=1 (nothing is
#                              written). Missing confirmation aborts loudly,
#                              naming the exact vars (#95 QA blocker 4).
#
# Not `set -e`: model probes are expected to fail for unavailable models; failures
# are counted and reported at the end so an incomplete run is never silent.
set -uo pipefail

export AWS_PROFILE="${AWS_PROFILE:?set AWS_PROFILE}"
cd "$(dirname "$0")" || exit 1

# Backoff/poll waits go through this seam so retry/poll timing is tunable and the
# offline readiness test (tests/register-models-readiness.test.sh) can drive the
# 502→200 / zero→visible transitions without real-time sleeps. Defaults to a real
# sleep; TG_SLEEP_CMD=: (a no-op) makes waits instant in tests.
tg_sleep() { ${TG_SLEEP_CMD:-sleep} "$@"; }

# Secret-safe curl: auth header via an owner-only --config file, never on argv (#50).
#   tg_curl "Authorization: Bearer" "$KEY" <curl args...>
tg_curl() {
  local hname="$1" secret="$2"; shift 2
  local cfg rc=0; cfg="$(mktemp)"; chmod 600 "$cfg"
  trap 'rm -f "$cfg"' RETURN   # + explicit rm below: cleanup even on forced curl failure (#50)
  printf 'header = "%s %s"\n' "$hname" "$secret" > "$cfg"
  curl --config "$cfg" "$@" || rc=$?
  rm -f "$cfg"; return "$rc"
}
# Region source of truth: <env>.tfvars (pass ENV=<env>), else explicit REGION.
# No silent us-east-1 default — an unspecified region is an error, so models are
# never routed to the wrong region than the deployed infra.
if [ -z "${REGION:-}" ] && [ -n "${ENV:-}" ] && [ -f "${ENV}.tfvars" ]; then
  REGION="$(sed -n 's/^[[:space:]]*region[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "${ENV}.tfvars" | head -1)"
fi
REGION="${REGION:-${AWS_REGION:-}}"
[ -n "$REGION" ] || { echo "ERROR: region unknown — pass ENV=<env> (reads <env>.tfvars) or REGION=<region>" >&2; exit 1; }
if [ -n "${AWS_REGION:-}" ] && [ "$AWS_REGION" != "$REGION" ]; then
  echo "ERROR: AWS_REGION=$AWS_REGION != resolved region=$REGION" >&2; exit 1
fi
export AWS_REGION="$REGION"
LITELLM_URL="${LITELLM_URL:?set LITELLM_URL (e.g. http://<alb-dns>)}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:?set LITELLM_MASTER_KEY}"
MANTLE_BASE="https://bedrock-mantle.${REGION}.api.aws/openai/v1"
BEDROCK_API_KEY_ENV="${BEDROCK_API_KEY_ENV:-BEDROCK_API_KEY}"
DRY_RUN="${DRY_RUN:-0}"

# Wizard mode (#95) — see header. All default to today's behavior when WIZARD=0.
# Capture "caller already supplied this" BEFORE applying defaults below, so
# wizard_prompts() can tell an explicit env value (skip the question, even at a
# TTY) apart from a value that only exists because of the default here.
#
# _SET uses ${VAR+1} (true even for an EXPLICIT EMPTY value), and the default is
# applied with ${VAR:-default} ONLY when _SET is unset — so an explicitly-empty
# WIZARD_DELETE_SCOPE='' stays empty and is caught by wizard_validate_enums,
# rather than being silently promoted to the destructive "both" (Codex F2: the
# old ${VAR:+1} + ${VAR:-default} pair let '' become both and pass validation).
WIZARD_MODE_SET="${WIZARD_MODE+1}"
WIZARD_DELETE_SCOPE_SET="${WIZARD_DELETE_SCOPE+1}"
SCOPE_SET="${SCOPE+1}"
WIZARD="${WIZARD:-0}"
[ -n "${WIZARD_MODE_SET:-}" ] || WIZARD_MODE="clean"
[ -n "${WIZARD_DELETE_SCOPE_SET:-}" ] || WIZARD_DELETE_SCOPE="both"
[ -n "${SCOPE_SET:-}" ] || SCOPE="both"
WIZARD_INCLUDE="${WIZARD_INCLUDE:-}"
WIZARD_EXCLUDE="${WIZARD_EXCLUDE:-}"
SKIP_DELETE="${SKIP_DELETE:-0}"
WIZARD_CONFIRM="${WIZARD_CONFIRM:-0}"
WIZARD_TTY="0"; [ -t 0 ] && WIZARD_TTY="1"
WIZARD_SELECTED_N=-1   # set by wizard_select to the count of models it selected; -1 = wizard off / not run

# Multi-tenant / cross-account (all optional)
TENANT="${TENANT:-}"                          # e.g. bu-a  -> model names bu-a/<model>
BEDROCK_ROLE_ARN="${BEDROCK_ROLE_ARN:-}"       # tenant's Bedrock role to AssumeRole into
BEDROCK_EXTERNAL_ID="${BEDROCK_EXTERNAL_ID:-}" # trust-policy external id

# Discovery creds. Single-account: defaults to AWS_PROFILE. Cross-account: you
# MUST pass a profile that can list models in the tenant account — there is no
# fallback known-model list, so fail loudly rather than silently discover from
# the hub account (which would list the wrong account's models).
if [ -n "$BEDROCK_ROLE_ARN" ]; then
  if [ -z "${DISCOVER_PROFILE:-}" ]; then
    echo "ERROR: cross-account run (BEDROCK_ROLE_ARN set) requires DISCOVER_PROFILE" >&2
    echo "       = credentials that can 'aws bedrock list-*' in the tenant account." >&2
    exit 1
  fi
  # Verify DISCOVER_PROFILE actually points at the tenant account (the account in
  # BEDROCK_ROLE_ARN) — not the hub. Otherwise we'd discover the wrong account's
  # models while registering routes that AssumeRole into the tenant.
  role_acct="$(printf '%s' "$BEDROCK_ROLE_ARN" | sed -n 's/^arn:aws:iam::\([0-9]\{12\}\):.*/\1/p')"
  disc_acct="$(AWS_PROFILE="$DISCOVER_PROFILE" aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  if [ -z "$disc_acct" ]; then
    echo "ERROR: DISCOVER_PROFILE=$DISCOVER_PROFILE has no valid credentials" >&2; exit 1
  fi
  if [ -n "$role_acct" ] && [ "$role_acct" != "$disc_acct" ]; then
    echo "ERROR: DISCOVER_PROFILE account ($disc_acct) != BEDROCK_ROLE_ARN account ($role_acct)." >&2
    echo "       Discovery must run in the tenant account, not the hub." >&2
    exit 1
  fi
fi
DISCOVER_PROFILE="${DISCOVER_PROFILE:-$AWS_PROFILE}"

PREFIX=""; [ -n "$TENANT" ] && PREFIX="${TENANT}/"
SESSION_NAME="litellm-${TENANT:-default}"
FAILS=0
REG_N=0   # count of successful /model/new registrations this run (wizard summary line)

echo "==> hub account: $(aws sts get-caller-identity --query Account --output text)  region: $REGION"
[ -n "$TENANT" ] && echo "==> tenant: $TENANT  bedrock-role: ${BEDROCK_ROLE_ARN:-<none>}  discover-profile: $DISCOVER_PROFILE  prefix: $PREFIX"
echo "==> gateway: $LITELLM_URL"

# Cross-account params appended to a model's litellm_params (empty if single-acct).
# Applied to BOTH bedrock-runtime (Claude/gpt-oss) AND Mantle (Codex) models so a
# tenant's Codex traffic also runs in the tenant account, not the hub.
xacct() {
  [ -z "$BEDROCK_ROLE_ARN" ] && { echo ""; return; }
  local x=",\"aws_role_name\":\"$BEDROCK_ROLE_ARN\",\"aws_session_name\":\"$SESSION_NAME\""
  [ -n "$BEDROCK_EXTERNAL_ID" ] && x="$x,\"aws_external_id\":\"$BEDROCK_EXTERNAL_ID\""
  echo "$x"
}
XACCT="$(xacct)"

# ---- Wizard mode (#95): a few plain questions, sensible defaults, one summary
# before anything happens — modeled on the ~/ccwb-iam `tg install` UX. Dead code
# when WIZARD=0 (wizard_ask short-circuits and every var already carries its
# non-interactive default from the block above).
#
# wizard_ask <var_name> <why> <prompt> <default> [choices...]
# Precedence: caller-supplied env var wins outright (checked by callers before
# invoking this, so the prompt is skipped even at a TTY); otherwise a TTY prompts
# with the default preselected (bare Enter accepts it); otherwise (no TTY) the
# default silently applies — this function is only reached when the answer isn't
# already known, so it just needs to decide "ask or use the default already set".
wizard_ask() {
  local __var="$1" why="$2" prompt="$3" default="$4"; shift 4
  if [ "$WIZARD_TTY" != "1" ]; then return 0; fi
  echo; echo "  $why"
  local i=1 c
  for c in "$@"; do echo "    $i) $c"; i=$((i+1)); done
  local ans; read -r -p "  $prompt [$default]: " ans
  [ -n "$ans" ] || ans="$default"
  printf -v "$__var" '%s' "$ans"
}

# wizard_prompts: drives Steps 1-3 (mode, delete scope, bare-alias scope). Each
# question is skipped if its var arrived already set (env/CI-scripted), so a
# partially-scripted run only asks what it doesn't already know.
wizard_prompts() {
  [ "$WIZARD" = "1" ] || return 0
  echo "==> wizard mode (#95): a few questions, then one summary before anything happens"
  if [ -z "${WIZARD_MODE_SET:-}" ]; then
    local mode_default_idx=2; [ "$WIZARD_MODE" = "additive" ] && mode_default_idx=1
    wizard_ask WIZARD_MODE \
      "Choosing whether to reset existing registrations before adding new ones." \
      "What do you want to do?" "$mode_default_idx" \
      "Register new models only (additive)" "Clean slate - delete existing and re-register"
    case "$WIZARD_MODE" in 1) WIZARD_MODE=additive ;; 2) WIZARD_MODE=clean ;; esac
  fi
  if [ "$WIZARD_MODE" = "clean" ] && [ -z "${WIZARD_DELETE_SCOPE_SET:-}" ]; then
    local del_default_idx=3
    case "$WIZARD_DELETE_SCOPE" in claude) del_default_idx=1 ;; mantle) del_default_idx=2 ;; both) del_default_idx=3 ;; esac
    wizard_ask WIZARD_DELETE_SCOPE \
      "Choosing what to delete before re-registering (clean-slate mode)." \
      "Delete which existing models?" "$del_default_idx" \
      "claude" "mantle" "both"
    case "$WIZARD_DELETE_SCOPE" in 1) WIZARD_DELETE_SCOPE=claude ;; 2) WIZARD_DELETE_SCOPE=mantle ;; 3) WIZARD_DELETE_SCOPE=both ;; esac
  fi
  if [ -z "${SCOPE_SET:-}" ]; then
    local scope_default_idx=3
    case "$SCOPE" in us) scope_default_idx=1 ;; global) scope_default_idx=2 ;; both) scope_default_idx=3 ;; esac
    wizard_ask SCOPE \
      "Choosing which routing scope wins the bare (unscoped) Claude alias. This never changes which global/<model> and us/<model> aliases get registered — both are always registered (#20)." \
      "Which scope should the bare Claude alias prefer?" "$scope_default_idx" \
      "us" "global" "both"
    case "$SCOPE" in 1) SCOPE=us ;; 2) SCOPE=global ;; 3) SCOPE=both ;; esac
  fi
}

# Fail closed on any unrecognized enum value (#95 QA defect 1). Both interactive
# (a mistyped number that no case above mapped) and env-scripted runs land here —
# a bad WIZARD_DELETE_SCOPE/SCOPE must ABORT, never silently fall through to the
# most destructive "both"/default branch. Runs after wizard_prompts so it also
# catches an unmapped TTY answer.
wizard_validate_enums() {
  [ "$WIZARD" = "1" ] || return 0
  case "$WIZARD_MODE" in additive|clean) ;; *) echo "ERROR(#95): WIZARD_MODE='$WIZARD_MODE' invalid (want additive|clean)" >&2; exit 1 ;; esac
  case "$WIZARD_DELETE_SCOPE" in claude|mantle|both) ;; *) echo "ERROR(#95): WIZARD_DELETE_SCOPE='$WIZARD_DELETE_SCOPE' invalid (want claude|mantle|both)" >&2; exit 1 ;; esac
  case "$SCOPE" in us|global|both) ;; *) echo "ERROR(#95): SCOPE='$SCOPE' invalid (want us|global|both)" >&2; exit 1 ;; esac
}
wizard_prompts
wizard_validate_enums

# ---- 1. Claude: register BOTH global and us inference profiles under scope-
# prefixed names so operators/devs can pick routing scope explicitly (#20).
# alias = "<scope>/<model>" (e.g. global/claude-opus-4-8, us/claude-opus-4-8);
# value keeps the EXACT AWS inference-profile ID. No global-wins collapsing.
echo "==> discovering Claude models + inference profiles (via $DISCOVER_PROFILE)"
# Capture the discovery command's REAL exit status (not the pipe's) so an
# auth/throttle/permission failure is detected rather than silently yielding an
# empty profile list. In WIZARD clean mode an empty list would otherwise let the
# delete phase wipe working rows and register nothing (#95 QA blocker 3: failed
# discovery must abort BEFORE any destructive delete, never fail open).
CLAUDE_DISCOVERY_OK=1
# Capture the aws call's REAL exit status IN THIS shell (plain command
# substitution + explicit `rc=$?`), not via `< <(process substitution)` — the
# latter runs in a subshell, so a CLAUDE_DISCOVERY_OK=0 set inside it would be
# lost and a failed listing would masquerade as an empty-but-successful result.
# On failure we still leave the array empty but flag it so wizard_delete_phase
# aborts BEFORE any destructive delete (#95 QA blocker 3 — no fail-open).
# stderr is sent to a temp file (NOT folded into stdout with 2>&1) so an AWS
# warning on a *successful* call can't slip in as a bogus profile id.
_ERR_G="$(mktemp)"; _ERR_U="$(mktemp)"
_GP_RAW="$(AWS_PROFILE="$DISCOVER_PROFILE" aws bedrock list-inference-profiles --region "$REGION" \
  --query "inferenceProfileSummaries[?starts_with(inferenceProfileId,'global.anthropic')].inferenceProfileId" \
  --output text 2>"$_ERR_G")"; _GP_RC=$?
_UP_RAW="$(AWS_PROFILE="$DISCOVER_PROFILE" aws bedrock list-inference-profiles --region "$REGION" \
  --query "inferenceProfileSummaries[?starts_with(inferenceProfileId,'us.anthropic')].inferenceProfileId" \
  --output text 2>"$_ERR_U")"; _UP_RC=$?
if [ "$_GP_RC" -ne 0 ]; then echo "ERROR: list-inference-profiles (global.anthropic) failed rc=$_GP_RC: $(cat "$_ERR_G")" >&2; CLAUDE_DISCOVERY_OK=0; _GP_RAW=""; fi
if [ "$_UP_RC" -ne 0 ]; then echo "ERROR: list-inference-profiles (us.anthropic) failed rc=$_UP_RC: $(cat "$_ERR_U")" >&2; CLAUDE_DISCOVERY_OK=0; _UP_RAW=""; fi
rm -f "$_ERR_G" "$_ERR_U"
mapfile -t GLOBAL_PROFILES < <(printf '%s' "$_GP_RAW" | tr '\t' '\n')
mapfile -t US_PROFILES     < <(printf '%s' "$_UP_RAW" | tr '\t' '\n')
unset _GP_RAW _UP_RAW _GP_RC _UP_RC _ERR_G _ERR_U

# wizard_bare_name <model-or-id-tail> -> stripped client-facing bare name.
# The single source of truth for how a discovered model collapses to its bare
# alias, so the BARE build, the SELECTED selection map, and the EOL/LEGACY table
# lookups all key off the exact same string (#95 QA defect 2). Under WIZARD=0 the
# callers keep today's byte-for-byte behavior (they don't call this); under
# WIZARD=1: dots→dashes already done by the caller for Claude, then drop a
# trailing -v1:0 and a trailing -YYYYMMDD date so dated profiles share one alias.
wizard_bare_name() {
  # Drop a trailing version (-vN:M, any version — not just -v1:0) then a trailing
  # -YYYYMMDD date, so e.g. claude-3-5-sonnet-20240620-v1:0 and
  # claude-3-5-sonnet-20241022-v2:0 both collapse to claude-3-5-sonnet (Codex F3:
  # the old -v1:0-only strip left -v2:0 profiles dated and unable to match the
  # stripped EOL/LEGACY table keys).
  printf '%s' "$1" | sed -E 's/-v[0-9]+:[0-9]+$//; s/-[0-9]{8}$//'
}

declare -A CLAUDE=()   # "<scope>/<model>" -> exact inference-profile id (=() — see BARE below)
add_claude() {
  local pid="$1"                                   # e.g. global.anthropic.claude-opus-4-8  OR us.anthropic.claude-3-5-sonnet-20240620-v1:0
  local scope="${pid%%.anthropic.*}"               # global | us
  local base="${pid#*.anthropic.}"                 # claude-opus-4-8 | claude-3-5-sonnet-20240620-v1:0
  # keep a date/version component when present so distinct profiles cannot collide
  base="${base%-v1:0}"                             # drop trailing -v1:0 only
  local model="${base//./-}"                       # dots -> dashes for a clean name
  local alias="${scope}/${model}"                  # global/claude-opus-4-8
  # idempotent within this run; distinct pids keep distinct names (date retained)
  CLAUDE["$alias"]="$pid"
}
for p in "${GLOBAL_PROFILES[@]}"; do [ -n "$p" ] && add_claude "$p"; done
for p in "${US_PROFILES[@]}";    do [ -n "$p" ] && add_claude "$p"; done

# Bare, client-compatible Claude aliases (#45). Claude Code rejects slash/scope
# aliases (global/…, us/…) with HTTP 400, so a fresh account that serves ONLY the
# scoped names has no CLI-usable Claude model — the documented `--create …
# claude-opus-4-8` then names a model that isn't served. Register a deterministic
# bare alias per model, GLOBAL-preferred (us as fallback) by default, pointing at
# the SAME profile. This is ADDITIVE — the explicit global/ and us/ scope names
# still exist for scope selection, so #20's no-global-wins-collapse contract holds
# for the scoped names; the bare name is a documented convenience that defaults to
# global. Under WIZARD=1, SCOPE (#95) can pin the bare alias to one scope only
# (no fallback) instead of the default preferred+fallback behavior; SCOPE never
# narrows which scope-prefixed aliases get registered above.
declare -A BARE=()   # "claude-opus-4-8" -> exact inference-profile id (global preferred)
# The =() literal matters under `set -u`: an empty associative array declared
# without it reads as unbound for `${#BARE[@]}` (bash 5.2), which SCOPE=us/global
# with zero matches in that scope would hit at lines below and at the summary.
BARE_PREF="global"; BARE_ONLY=""
if [ "$WIZARD" = "1" ]; then
  case "$SCOPE" in
    us)     BARE_PREF="us"; BARE_ONLY="us" ;;
    global) BARE_PREF="global"; BARE_ONLY="global" ;;
    *)      BARE_PREF="global" ;;   # both/unset: today's preferred+fallback
  esac
fi
for alias in "${!CLAUDE[@]}"; do
  scope="${alias%%/*}"; model="${alias#*/}"
  # Bug #1 fix, gated behind WIZARD=1 so the default path is byte-for-byte
  # unchanged: a dated inference-profile name (claude-3-5-sonnet-20240620) must
  # not leak its date suffix into the client-facing bare alias.
  bare_name="$model"
  [ "$WIZARD" = "1" ] && bare_name="$(wizard_bare_name "$model")"
  [ -n "$BARE_ONLY" ] && [ "$scope" != "$BARE_ONLY" ] && continue
  # prefer the BARE_PREF-scoped profile for the bare name; only let the other
  # scope fill an empty slot
  if [ "$scope" = "$BARE_PREF" ] || [ -z "${BARE[$bare_name]:-}" ]; then
    BARE["$bare_name"]="${CLAUDE[$alias]}"
  fi
done
if [ "${#CLAUDE[@]}" -eq 0 ]; then
  echo "   WARNING: no Claude inference profiles found in $REGION via $DISCOVER_PROFILE." >&2
  echo "            (check Bedrock model access + that the profile can list profiles)" >&2
  FAILS=$((FAILS+1))
else
  echo "   Claude profiles to register (scope-prefixed): ${!CLAUDE[*]}"
fi

# ---- 2. OpenAI/Mantle: probe the Responses endpoint ----
echo "==> probing Mantle (Responses API) OpenAI models (via $DISCOVER_PROFILE)"
# Probe transport goes through a seam (like tg_sleep) so the offline wizard test
# can drive OK/NO deterministically without a real SigV4 request. TG_MANTLE_PROBE_CMD,
# when set, is run as `<cmd> <model> <region>` and must echo OK|NO; unset uses the
# real boto3/requests probe below. Defaults to the real probe in every non-test run.
probe_mantle() {
  if [ -n "${TG_MANTLE_PROBE_CMD:-}" ]; then
    $TG_MANTLE_PROBE_CMD "$1" "$REGION"; return
  fi
  AWS_PROFILE="$DISCOVER_PROFILE" python3 - "$1" "$REGION" <<'PY' 2>/dev/null
import json,sys,boto3,requests
from botocore.auth import SigV4Auth; from botocore.awsrequest import AWSRequest
M,R=sys.argv[1],sys.argv[2]
url=f"https://bedrock-mantle.{R}.api.aws/openai/v1/responses"
body=json.dumps({"model":M,"input":"ping"})
c=boto3.Session().get_credentials().get_frozen_credentials()
req=AWSRequest(method="POST",url=url,data=body,headers={"Content-Type":"application/json"})
SigV4Auth(c,"bedrock",R).add_auth(req)
r=requests.post(url,data=body,headers=dict(req.headers),timeout=25)
print("OK" if r.status_code==200 else "NO")
PY
}
MANTLE_CANDIDATES=(openai.gpt-5.5 openai.gpt-5.4 openai.gpt-5 openai.gpt-5.6 \
                   openai.gpt-5.6-sol openai.gpt-5.6-luna openai.gpt-5.6-terra \
                   openai.gpt-5.5-codex openai.gpt-5.4-codex)

# Wizard-mode (#95) EOL/legacy classification. A release-pinned fact about AWS's
# model lifecycle — identical for every tenant/env/account — so it stays a named
# constant, not an env-injectable value (the per-run override seam is
# WIZARD_INCLUDE/WIZARD_EXCLUDE at the selection layer, not here).
#
# Keys MUST be the STRIPPED bare model name — the exact form wizard_bare_name()
# produces (dots→dashes, trailing -v1:0 and -YYYYMMDD dropped) — because selection
# (wizard_select) is keyed by that stripped name, not the raw inference-profile id
# (#95 QA defect 2: dated keys here never matched the stripped selection keys).
# EOL/legacy rows are shown but left UNCHECKED by default in Step 4; a user can
# re-check them via the TTY toggle or WIZARD_INCLUDE.
#
# Coverage note (Codex F3): the dated Claude 3.5 Sonnet profiles
# (claude-3-5-sonnet-20240620-v1:0, claude-3-5-sonnet-20241022-v2:0) BOTH strip to
# claude-3-5-sonnet, so a single stripped key covers every dated variant — list it
# explicitly so those still-discoverable retired profiles are off by default.
declare -A WIZARD_EOL=(
  [claude-3-sonnet]=1
  [claude-sonnet-4]=1
  [claude-3-5-sonnet]=1
)
declare -A WIZARD_LEGACY=(
  [claude-3-haiku]=1
  [claude-3-5-haiku]=1
)

declare -a MANTLE_OK=()   # =() — the wizard summary's ${#MANTLE_OK[@]} (line ~482) would
                          # otherwise read as unbound under set -u on a Claude-only account
for m in "${MANTLE_CANDIDATES[@]}"; do
  [ "$(probe_mantle "$m")" = "OK" ] && { MANTLE_OK+=("$m"); echo "   mantle: $m AVAILABLE"; }
done
[ "${#MANTLE_OK[@]}" -eq 0 ] && echo "   (no Mantle/Codex models reachable in $REGION — Codex will be unavailable; that's fine if you don't use it)"

# gpt-oss discovery — capture the command's exit status (don't hide errors in a
# pipe/process-substitution) so an API/permission failure is counted, not silent.
OSS_RAW=""
if OSS_RAW="$(AWS_PROFILE="$DISCOVER_PROFILE" aws bedrock list-foundation-models --region "$REGION" --by-provider openai \
      --query "modelSummaries[?contains(modelId,'gpt-oss')].modelId" --output text 2>&1)"; then
  mapfile -t OSS < <(printf '%s' "$OSS_RAW" | tr '\t' '\n')
  [ -n "${OSS_RAW// /}" ] || echo "   (no gpt-oss models found in $REGION)"
else
  echo "   WARNING: gpt-oss discovery failed in $REGION via $DISCOVER_PROFILE: ${OSS_RAW:0:120}" >&2
  FAILS=$((FAILS+1)); OSS=()
fi

# ---- 3. Register ----
# Idempotent: skip a model_name that already exists (avoids the 22→44 duplication
# on rerun, #13). Honest success: only print "registered" when the API returns a
# model_id and no error — no blanket "+ $name" fallback that masks failures (#13).
existing_models() {
  tg_curl "Authorization: Bearer" "$LITELLM_MASTER_KEY" -s "$LITELLM_URL/model/info" 2>/dev/null \
    | python3 -c "import sys,json;print('\n'.join(m.get('model_name','') for m in json.load(sys.stdin).get('data',[])))" 2>/dev/null
}

# ---- Wizard mode (#95): delete phase. Runs BEFORE the EXISTING snapshot below
# so a deleted row is actually gone by the time reg()'s idempotency check runs
# (otherwise reg() would see the stale row and wrongly skip re-registration).
# Dead code when WIZARD=0.

# existing_models_full: like existing_models() (unchanged, other callers depend
# on its name-only output) but also returns each row's model_info.id, needed for
# /model/delete. "id\tname" pairs, one per line.
existing_models_full() {
  tg_curl "Authorization: Bearer" "$LITELLM_MASTER_KEY" -s "$LITELLM_URL/model/info" 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
for m in d.get('data', []):
    mid = (m.get('model_info') or {}).get('id', '')
    name = m.get('model_name', '')
    if mid and name:
        print(f'{mid}\t{name}')
" 2>/dev/null
}

# wizard_classify <name> -> claude|mantle|other, for clean-mode deletion.
#
# Ownership model (owner decision, 2026-07-29): in these gateways EVERY model was
# registered by THIS script, except LiteLLM's own out-of-box defaults. There are
# no hand-added models to protect and no multi-tenant foreign rows. So clean mode
# deletes any row matching one of our own name forms (below); we do NOT try to
# carve out look-alike hand-added names — that guarantee is stronger than the
# environment needs and cannot be delivered from the name alone (a hand-added
# `global/claude-private` is byte-identical to a script-owned scoped alias).
# Cleaning up leftovers from an older script version is an accepted one-time cost.
#
# A leading tenant "<TENANT>/" namespace (#33 cross-account naming) is stripped
# first if present, so a prefixed row still matches the bare forms; an unprefixed
# our-shaped row is equally ours and also matches. Genuinely unrelated names that
# match none of our forms (gpt-4o-mine, my-thing, someone-elses/model) classify
# "other" and are left alone — but that is incidental, not a safety guarantee.
#
# Script-owned Claude forms:  global.anthropic.* | us.anthropic.*  (canonical id)
#                             global/claude-*    | us/claude-*      (scoped alias)
#                             claude-*                              (bare alias)
# Script-owned Mantle forms:  openai.gpt-5* | openai.gpt-oss*       (canonical id)
#                             gpt-5-* | gpt-5                        (legacy rewrite,
#                                                                     incl. bare gpt-5)
#                             gpt-oss-*                             (bare gpt-oss)
wizard_classify() {
  local name="$1"
  [ -n "$PREFIX" ] && name="${name#"$PREFIX"}"   # strip this run's tenant namespace if present
  case "$name" in
    global.anthropic.*|us.anthropic.*|global/claude-*|us/claude-*|claude-*) echo claude ;;
    openai.gpt-5*|openai.gpt-oss*|gpt-5-*|gpt-5|gpt-oss-*)                   echo mantle ;;
    *)                                                                       echo other ;;
  esac
}

# del <id> <name>: mirrors reg()'s exact retry/backoff shape (#52-style: retry
# on edge 502/503/504/000, bounded attempts) and tg_curl's secret-safe auth;
# honors DRY_RUN; increments the existing FAILS counter on unrecoverable
# failure so a failed delete still produces a non-zero exit.
del() {
  local id="$1" name="$2"
  if [ "$DRY_RUN" = "1" ]; then echo "   [dry-run] delete $name (id=$id)"; return; fi
  local resp body code attempt=0 max_attempts=8
  while :; do
    resp="$(tg_curl "Authorization: Bearer" "$LITELLM_MASTER_KEY" -s -w '\n%{http_code}' \
      -X POST "$LITELLM_URL/model/delete" \
      -H "Content-Type: application/json" \
      -d "{\"id\":\"$id\"}")"
    code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
    case "$code" in
      502|503|504|000)
        attempt=$((attempt+1))
        if [ "$attempt" -ge "$max_attempts" ]; then
          echo "   ! FAILED delete $name (id=$id): edge $code after $attempt attempts"; FAILS=$((FAILS+1)); return
        fi
        tg_sleep $((attempt < 6 ? attempt*5 : 30))
        continue ;;
      *) resp="$body"; break ;;
    esac
  done
  if printf '%s' "$resp" | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if not d.get('error') else 1)" 2>/dev/null; then
    echo "   - deleted $name (id=$id)"; DEL_N=$((DEL_N+1))
  elif printf '%s' "$resp" | grep -qi 'not found in db'; then
    # Already gone -- e.g. a name that also appears in proxy_config.model_list
    # (tfvars-static, never a DB row to begin with). Idempotent, not a failure;
    # mirrors reg()'s existing skip-if-already-registered idempotency. Found live
    # against a real gateway during the #95 demo0 smoke test.
    echo "   = $name already absent (id=$id, not a DB row -- skip)"
  else
    echo "   ! FAILED delete $name (id=$id): $(printf '%s' "$resp" | head -c 120)"; FAILS=$((FAILS+1))
  fi
}

# ---- Wizard mode (#95): WHOLE-MODEL selection (QA defects 2 & 4).
#
# A single selection pass keyed by the STRIPPED bare model name decides, once,
# whether a discovered model is registered — and that one decision gates EVERY
# form of it (Claude canonical inference-profile id + global/us scoped aliases +
# bare alias; Mantle canonical id + legacy rewrite; gpt-oss alias). Deselecting a
# model therefore drops ALL its registrations, not just the bare Claude alias
# (the old wizard_review only touched BARE — defect 4).
#
# SELECTED[<key>]=1 means "register this model's forms". Registration consults it
# via wizard_keep(). When WIZARD=0 SELECTED is empty and wizard_keep() is a no-op
# that keeps everything (today's behavior, byte-for-byte).
declare -A SELECTED=()

# wizard_claude_key <alias>  ->  the stripped bare name for a "<scope>/<model>"
# CLAUDE alias, i.e. the same key the bare loop and EOL/LEGACY tables use.
wizard_claude_key() { local m="${1#*/}"; wizard_bare_name "$m"; }

# wizard_keep <key>: true if this model form should be registered. Keeps
# everything when WIZARD=0; otherwise only keys present in SELECTED.
wizard_keep() {
  [ "$WIZARD" = "1" ] || return 0
  [ -n "${SELECTED[$1]:-}" ]
}

# wizard_select: build SELECTED from the full discovered universe (Claude bare
# names + available Mantle ids + gpt-oss aliases). Off-by-default for EOL/legacy
# Claude; WIZARD_EXCLUDE removes, WIZARD_INCLUDE re-adds (or overrides an EOL/
# legacy default), EXCLUDE wins over INCLUDE. At a TTY, Step 4 shows the whole
# checklist (available-and-selected [x], EOL/legacy/unavailable [ ]) and lets the
# operator toggle any row. Unavailable Mantle candidates are SHOWN (so the
# operator sees they exist) but never selected — they were never reachable.
wizard_select() {
  [ "$WIZARD" = "1" ] || return 0
  # 1) Enumerate the discovered universe as (key, kind, available) rows. kind is
  #    for the EOL/legacy default + the checklist label; available=0 rows (only
  #    unavailable Mantle) are displayed but never auto-selected.
  local -a keys=() kinds=() avail=()
  local k m
  local -A seen=()
  # Claude universe = the FULL discovered CLAUDE set (every scope), collapsed to
  # stripped bare keys — NOT the BARE map, which SCOPE has already narrowed to one
  # scope (Codex F1: SCOPE=us with global-only profiles left BARE — and therefore
  # SELECTED — empty, so clean mode would delete then register nothing). Selection
  # is a whole-model decision independent of which scope wins the bare alias.
  for m in "${!CLAUDE[@]}"; do
    k="$(wizard_bare_name "${m#*/}")"          # "<scope>/<model>" -> stripped bare name
    [ -n "${seen[$k]:-}" ] && continue; seen[$k]=1
    keys+=("$k"); avail+=(1)
    if [ -n "${WIZARD_EOL[$k]:-}" ]; then kinds+=("eol")
    elif [ -n "${WIZARD_LEGACY[$k]:-}" ]; then kinds+=("legacy")
    else kinds+=("claude"); fi
  done
  for m in "${MANTLE_OK[@]}"; do
    [ -n "${seen[$m]:-}" ] && continue; seen[$m]=1
    keys+=("$m"); kinds+=("mantle"); avail+=(1)
  done
  for m in "${MANTLE_CANDIDATES[@]}"; do        # unavailable Mantle: show, don't select
    [ -n "${seen[$m]:-}" ] && continue; seen[$m]=1
    keys+=("$m"); kinds+=("mantle-unavailable"); avail+=(0)
  done
  local a
  for m in "${OSS[@]:-}"; do
    [ -z "$m" ] && continue
    a="${m%%-1:0}"; a="${a#openai.}"
    [ -n "${seen[$a]:-}" ] && continue; seen[$a]=1
    keys+=("$a"); kinds+=("gpt-oss"); avail+=(1)
  done

  # 2) Default selection: available rows on, EOL/legacy off, then EXCLUDE/INCLUDE.
  local i sel kind
  for i in "${!keys[@]}"; do
    k="${keys[$i]}"; kind="${kinds[$i]}"
    sel="${avail[$i]}"                                   # available on, unavailable off
    case "$kind" in eol|legacy) sel=0 ;; esac           # EOL/legacy off by default
    case " $WIZARD_INCLUDE " in *" $k "*|*" all "*) [ "${avail[$i]}" = "1" ] && sel=1 ;; esac
    case " $WIZARD_EXCLUDE " in *" $k "*|*" all "*) sel=0 ;; esac   # EXCLUDE wins
    [ "$sel" = "1" ] && SELECTED["$k"]=1
  done

  # 3) TTY: show the whole checklist and let the operator toggle any row.
  if [ "$WIZARD_TTY" = "1" ] && [ "${#keys[@]}" -gt 0 ]; then
    echo; echo "  Step 4: review discovered models — toggle any by number (EOL/legacy/unavailable off by default)"
    for i in "${!keys[@]}"; do
      k="${keys[$i]}"; kind="${kinds[$i]}"
      local box="[ ]"; [ -n "${SELECTED[$k]:-}" ] && box="[x]"
      local tag=""
      case "$kind" in
        eol)                tag="  <- EOL, off by default" ;;
        legacy)             tag="  <- legacy, off by default" ;;
        mantle-unavailable) tag="  <- not reachable, cannot register" ;;
      esac
      echo "    $((i+1)) ) $box $k$tag"
    done
    local toggled idx key
    read -r -p "  Toggle any by number (space-separated), or Enter to accept: " toggled
    for idx in $toggled; do
      # Require a POSITIVE integer in range: idx=0 would make $((idx-1)) = -1,
      # which bash resolves as the LAST array element — a mistyped 0 must not
      # silently toggle the final row (Codex F6).
      [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#keys[@]}" ] || { echo "    (ignoring out-of-range choice: $idx)"; continue; }
      key="${keys[$((idx-1))]:-}"; [ -n "$key" ] || continue
      if [ -n "${SELECTED[$key]:-}" ]; then
        unset "SELECTED[$key]"
      elif [ "${avail[$((idx-1))]}" = "1" ]; then       # cannot select an unavailable model
        SELECTED["$key"]=1
      else
        echo "    ($key is not reachable — cannot be selected)"
      fi
    done
  fi

  # Capture the FINAL selected count AFTER any TTY toggles (Codex F5): the empty-
  # selection serving-check skip must reflect what the operator actually left
  # selected, not the pre-toggle defaults — otherwise enabling a model at the TTY
  # could still skip the #13 readiness check, or deselecting all could still run
  # (and falsely fail) it.
  WIZARD_SELECTED_N="${#SELECTED[@]}"
}

# wizard_delete_phase: Step 5 for any WIZARD=1 run — scan (clean mode only)
# the existing registrations to delete, print the provider-neutral summary, and
# gate the whole delete-then-register on ONE confirmation. The summary + confirm
# run for EVERY wizard run (clean, additive, and SKIP_DELETE alike) so no path
# mutates the gateway without Step 5 (#95 QA blocker 4). Only the delete SCAN is
# clean-mode-and-not-SKIP_DELETE; additive/SKIP_DELETE simply match zero rows.
wizard_delete_phase() {
  DEL_N=0
  [ "$WIZARD" = "1" ] || return 0

  # Fail-closed on incomplete discovery BEFORE anything destructive (#95 blocker
  # 3): if Claude discovery errored, an empty CLAUDE set would delete working
  # rows in clean mode and register nothing. Abort instead of failing open.
  if [ "${CLAUDE_DISCOVERY_OK:-1}" != "1" ]; then
    echo "ERROR(#95): Claude inference-profile discovery failed — aborting before any delete/register." >&2
    echo "  Refusing to run destructively on an incomplete model list. Fix credentials/permissions/region and re-run." >&2
    exit 1
  fi

  local -a match_ids=() match_names=()
  local id name class
  local do_delete=1
  [ "$WIZARD_MODE" = "clean" ] || do_delete=0
  if [ "$SKIP_DELETE" = "1" ]; then
    echo "==> wizard: SKIP_DELETE=1 — delete phase skipped (summary + confirm still apply)"
    do_delete=0
  fi
  if [ "$do_delete" = "1" ]; then
    echo "==> wizard: scanning existing registrations to delete (scope=$WIZARD_DELETE_SCOPE)"
    while IFS=$'\t' read -r id name; do
      [ -n "$id" ] && [ -n "$name" ] || continue
      class="$(wizard_classify "$name")"
      case "$WIZARD_DELETE_SCOPE" in
        claude) [ "$class" = "claude" ] || continue ;;
        mantle) [ "$class" = "mantle" ] || continue ;;
        *)      [ "$class" = "other" ] && continue ;;
      esac
      match_ids+=("$id"); match_names+=("$name")
    done < <(existing_models_full)
  fi
  local n="${#match_ids[@]}"

  # Count what the SELECTED-gated registration loops will actually emit, so the
  # summary reflects Step-4 deselections rather than the raw discovered totals
  # (#95). Mirrors the four register loops' own wizard_keep() gate + name forms.
  local reg_forms=0 a mm oa
  for a in "${!CLAUDE[@]}"; do
    wizard_keep "$(wizard_claude_key "$a")" && reg_forms=$((reg_forms+2))   # canonical + scoped
  done
  for a in "${!BARE[@]}"; do wizard_keep "$a" && reg_forms=$((reg_forms+1)); done
  for oa in "${OSS[@]:-}"; do
    [ -z "$oa" ] && continue
    mm="${oa%%-1:0}"; mm="${mm#openai.}"
    wizard_keep "$mm" && reg_forms=$((reg_forms+1))
  done
  for mm in "${MANTLE_OK[@]}"; do
    if wizard_keep "$mm"; then
      reg_forms=$((reg_forms+1))
      a="${mm#openai.}"; a="${a//./-}"; [ "$a" != "$mm" ] && reg_forms=$((reg_forms+1))   # legacy rewrite
    fi
  done

  echo "==> wizard summary"
  echo "   mode:              $WIZARD_MODE"
  if [ "$do_delete" = "1" ]; then
    echo "   delete scope:      $WIZARD_DELETE_SCOPE ($n existing model(s) matched)"
  else
    echo "   delete scope:      (none — $([ "$SKIP_DELETE" = "1" ] && echo SKIP_DELETE || echo additive), 0 model(s) will be deleted)"
  fi
  echo "   bare-alias scope:  $SCOPE"
  echo "   will register:     $reg_forms name(s) across selected models"

  # Step 5 confirmation gates the whole run. Interactive: always ask. Non-
  # interactive: require WIZARD_CONFIRM=1 whenever the run will MUTATE the gateway
  # (delete>0 OR register>0), so additive writes can't proceed unconfirmed either.
  if [ "$WIZARD_TTY" = "1" ]; then
    local ans; read -r -p "Proceed? [y/N]: " ans
    case "$ans" in y|Y|yes|YES) ;; *) echo "ERROR: wizard aborted (not confirmed)" >&2; exit 1 ;; esac
  elif { [ "$n" -gt 0 ] || [ "$reg_forms" -gt 0 ]; } && [ "$DRY_RUN" != "1" ] && [ "$WIZARD_CONFIRM" != "1" ]; then
    echo "ERROR(#95): a non-interactive wizard run would mutate the gateway ($n delete(s), $reg_forms registration(s))." >&2
    echo "  Set WIZARD_CONFIRM=1 to proceed, or DRY_RUN=1 to preview." >&2
    exit 1
  fi

  local i
  for i in "${!match_ids[@]}"; do
    del "${match_ids[$i]}" "${match_names[$i]}"
  done
}

wizard_select
wizard_delete_phase
EXISTING="$(existing_models)"
reg() {
  local name="$1" params="$2"
  if [ "$DRY_RUN" = "1" ]; then echo "   [dry-run] $name => $params"; return; fi
  if printf '%s\n' "$EXISTING" | grep -qxF "$name"; then
    echo "   = $name already registered (skip)"; return
  fi
  # Retry on EDGE 5xx (502/503/504) with backoff (#52). On a fresh deploy the
  # gateway app can be up and answer /health/liveliness 200 while the ALB target
  # group / CloudFront origin is not yet routing POSTs — those /model/new calls
  # get an edge 502 that never reaches the gateway. A brief post-apply routing gap
  # must self-heal instead of burning the registration window. Capture the HTTP
  # status separately (appended by -w) so we distinguish an edge 5xx from a real
  # gateway JSON error (which should NOT be retried).
  local resp body code attempt=0 max_attempts=8
  while :; do
    resp="$(tg_curl "Authorization: Bearer" "$LITELLM_MASTER_KEY" -s -w '\n%{http_code}' \
      -X POST "$LITELLM_URL/model/new" \
      -H "Content-Type: application/json" \
      -d "{\"model_name\":\"$name\",\"litellm_params\":$params}")"
    code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
    case "$code" in
      502|503|504|000)
        attempt=$((attempt+1))
        if [ "$attempt" -ge "$max_attempts" ]; then
          echo "   ! FAILED $name: edge $code after $attempt attempts (routing not ready)"; FAILS=$((FAILS+1)); return
        fi
        tg_sleep $((attempt < 6 ? attempt*5 : 30))   # 5,10,15,20,25,30,30… bounded backoff
        continue ;;
      *) resp="$body"; break ;;
    esac
  done
  if printf '%s' "$resp" | NAME="$name" python3 -c "import sys,os,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if (d.get('model_id') and not d.get('error')) else 1)" 2>/dev/null; then
    echo "   + registered $name"; REG_N=$((REG_N+1)); EXISTING="$EXISTING
$name"
  else
    echo "   ! FAILED $name: $(printf '%s' "$resp" | head -c 120)"; FAILS=$((FAILS+1))
  fi
}

# Provider-wide canonical-name invariant (#33): after an optional tenant
# namespace, the canonical gateway name preserves the backend identifier
# byte-for-byte. For Claude the backend id is the exact AWS inferenceProfileId
# (it already encodes global/us routing scope — the least-lossy contract).
#   single account : <inferenceProfileId>
#   cross account  : <TENANT>/<inferenceProfileId>
# The existing global/ + us/ friendly aliases are ALSO registered (additive
# migration — no rename, no deletion); both names route to the SAME profile and
# share pricing metadata. reg() is idempotent by model_name, so reruns and
# pre-existing rows do not duplicate. Tenant syntax is validated so it cannot
# collide with or impersonate an unprefixed canonical inferenceProfileId.
if [ -n "${TENANT:-}" ]; then
  case "$TENANT" in
    *.anthropic.*|*.*|*/*|"") echo "ERROR(#33): TENANT '$TENANT' must not contain '.', '/', or resemble an inferenceProfileId"; exit 1 ;;
  esac
fi
echo "==> registering Claude models (bedrock-runtime${TENANT:+, tenant $TENANT})"
for alias in "${!CLAUDE[@]}"; do
  # Whole-model gate (#95): if the operator deselected this model in Step 4, skip
  # EVERY form of it — canonical id AND scoped alias — not just the bare alias.
  wizard_keep "$(wizard_claude_key "$alias")" || continue
  pid="${CLAUDE[$alias]}"
  params="{\"model\":\"bedrock/$pid\",\"aws_region_name\":\"$REGION\"$XACCT}"
  # 1) canonical name = the exact inferenceProfileId, byte-for-byte, after the
  #    single tenant namespace. PREFIX already carries the tenant ("<TENANT>/" or
  #    ""), so apply it ONCE here — do NOT prepend $TENANT again (that produced
  #    <TENANT>/<TENANT>/<pid>). (#33)
  reg "${PREFIX}${pid}" "$params"
  # 2) friendly scope-prefixed alias, retained additively for back-compat
  reg "${PREFIX}${alias}" "$params"
done
# 3) bare client-compatible aliases (no slash) so Claude Code can actually use a
#    model on a fresh account (#45). Idempotent; global-preferred (see BARE build).
echo "==> registering bare client-compatible Claude aliases (Claude Code needs a non-slash id) (#45)"
for model in "${!BARE[@]}"; do
  wizard_keep "$model" || continue           # whole-model gate (#95)
  pid="${BARE[$model]}"
  params="{\"model\":\"bedrock/$pid\",\"aws_region_name\":\"$REGION\"$XACCT}"
  reg "${PREFIX}${model}" "$params"
done

echo "==> registering OpenAI gpt-oss models (bedrock-runtime)"
for m in "${OSS[@]}"; do
  [ -z "$m" ] && continue
  alias="${m%%-1:0}"; alias="${alias#openai.}"
  wizard_keep "$alias" || continue           # whole-model gate (#95)
  reg "${PREFIX}${alias}" "{\"model\":\"bedrock/$m\",\"aws_region_name\":\"$REGION\"$XACCT}"
done

# Mantle/Codex pricing. The route registers as `openai/openai.gpt-5.x`, which
# LiteLLM does NOT price by that key — so spend would log $0. But LiteLLM DOES
# ship prices under `bedrock_mantle/openai.gpt-5.x`. We look those up from
# LiteLLM's own published price map and pin them (so pricing comes from LiteLLM's
# defaults, populated at deploy time — not hand-maintained numbers). Models with
# no LiteLLM price fall back to an approximate rate (verify before billing).
echo "==> loading LiteLLM default prices for Mantle models"
PRICE_JSON="$(mktemp)"; trap 'rm -f "$PRICE_JSON"' EXIT
curl -sf -m 30 "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json" \
  -o "$PRICE_JSON" 2>/dev/null || echo "" > "$PRICE_JSON"
# lookup helper: echoes "IN OUT" (per-token) for bedrock_mantle/<id>, empty if none
litellm_price() { # $1 = openai.gpt-5.x
  PJ="$PRICE_JSON" python3 - "bedrock_mantle/$1" <<'PY' 2>/dev/null
import json,os,sys
key=sys.argv[1]
try: d=json.load(open(os.environ["PJ"]))
except Exception: sys.exit(0)
m=d.get(key,{})
i,o=m.get("input_cost_per_token"),m.get("output_cost_per_token")
if i is not None and o is not None: print(i,o)
PY
}
# approximate fallback (per-token) for models LiteLLM doesn't price yet
declare -A APPROX_IN=( [openai.gpt-5.5]=0.000005 [openai.gpt-5.4]=0.000005 [openai.gpt-5.6]=0.000005 )
declare -A APPROX_OUT=( [openai.gpt-5.5]=0.00003 [openai.gpt-5.4]=0.00003 [openai.gpt-5.6]=0.00003 )
echo "==> registering OpenAI frontier models (Bedrock Mantle, Responses API)"
if [ "${#MANTLE_OK[@]}" -gt 0 ] && [ -n "$BEDROCK_ROLE_ARN" ]; then
  echo "   NOTE: cross-account Codex is NOT auto-routed. The Mantle route uses a"
  echo "   bearer API key ($BEDROCK_API_KEY_ENV), not the AssumeRole params, so its"
  echo "   traffic bills to whichever account that key belongs to — set BEDROCK_API_KEY"
  echo "   to a key for the tenant account if you need tenant-account Codex billing."
fi
for m in "${MANTLE_OK[@]}"; do
  wizard_keep "$m" || continue               # whole-model gate (#95): Mantle is deselectable
  # Register the EXACT canonical Bedrock Mantle model ID as the primary alias.
  # Codex's bundled catalog sends canonical names (e.g. openai.gpt-5.6-sol) and
  # LiteLLM key policy compares the requested model to the allowed alias literally,
  # so a rewritten alias (gpt-5-6-sol) causes a policy 403 for Codex. (#30)
  price=""
  read -r pin pout <<< "$(litellm_price "$m")"
  if [ -n "${pin:-}" ] && [ -n "${pout:-}" ]; then
    price=",\"input_cost_per_token\":${pin},\"output_cost_per_token\":${pout}"
    echo "   $m: LiteLLM default price (in=$pin out=$pout)"
  elif [ -n "${APPROX_IN[$m]:-}" ]; then
    price=",\"input_cost_per_token\":${APPROX_IN[$m]},\"output_cost_per_token\":${APPROX_OUT[$m]}"
    echo "   $m: approximate price (LiteLLM has none — verify before billing)"
  else
    echo "   $m: NO price (LiteLLM none, no approx) — registering without a pin; spend logs \$0"
  fi
  # Mantle uses bearer auth (api_key), so AssumeRole params ($XACCT) do NOT apply here.
  params="{\"model\":\"openai/$m\",\"api_base\":\"$MANTLE_BASE\",\"api_key\":\"os.environ/$BEDROCK_API_KEY_ENV\"$price}"
  reg "${PREFIX}${m}" "$params"
  # Additively retain the legacy rewritten alias (openai.gpt-5.6-sol -> gpt-5-6-sol)
  # ONLY when it differs, pointing at the SAME route, so keys/docs issued before #30
  # keep working. reg() is idempotent, so this is collision-safe on rerun. (#30)
  legacy="${m#openai.}"; legacy="${legacy//./-}"
  if [ "$legacy" != "$m" ]; then
    reg "${PREFIX}${legacy}" "$params"
  fi
done

# Verify models actually SERVE (/v1/models), not just that DB rows exist. A green
# "registered" with an empty /v1/models is the #13 failure — surface it loudly and
# fail non-zero so the install banner cannot claim success over zero usable models.
#
# BUT the serving gateway reads DB rows on a short refresh cycle, so immediately
# after successful /model/new the served count can lag the persisted count for a
# few seconds before converging — a single-shot check here produced a FALSE zero
# and a false terminal failure (#53). Poll with bounded backoff: succeed as soon
# as models are visible; only fail after a clear timeout, and report persisted-vs-
# served counts so a real store_model_in_db problem (#13) is still distinguishable
# from a transient refresh lag.
served_count() {
  tg_curl "Authorization: Bearer" "$LITELLM_MASTER_KEY" -s "$LITELLM_URL/v1/models" \
    | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo 0
}
persisted_count() {
  tg_curl "Authorization: Bearer" "$LITELLM_MASTER_KEY" -s "$LITELLM_URL/model/info" \
    | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo 0
}
# Require COMPLETENESS, not merely nonzero (#53 R2 / #62): serving must catch up to
# the persisted set. A nonzero-but-partial snapshot (e.g. 40 of 73 while a gateway
# deployment is mid-rollout — which the installer itself triggers after minting the
# Codex key, #61) previously passed and then failed downstream Codex verification
# because Codex aliases weren't served yet. Poll until served >= persisted (both
# stable) with a longer bounded wait sized for a post-mint ECS rollout; only then
# is the model set truly ready. Fail closed after timeout with both counts.
#
# Exception (#95): a wizard run that INTENTIONALLY selected zero models (operator
# deselected everything in Step 4 / excluded all) legitimately registers nothing.
# With no pre-existing DB rows that yields persisted=0 — which is NOT the #13
# "registration silently produced nothing" failure, it's the operator's choice.
# Skip the fail-closed serving gate only in that exact case; any run that DID
# intend registrations still fails closed on an empty/partial served set.
if [ "$WIZARD" = "1" ] && [ "${WIZARD_SELECTED_N:-0}" -eq 0 ]; then
  echo "==> wizard: no models selected for registration — skipping the serving-completeness check (nothing to serve)."
  SERVED_N=0; PERSISTED_N=0
else
echo "==> waiting for the full registered model set to serve on /v1/models (served == persisted, bounded)"
SERVED_N=0; PERSISTED_N=0
for _ in $(seq 1 60); do          # ~60 * 5s = 5min bounded (covers a post-mint gateway redeploy)
  PERSISTED_N="$(persisted_count)"
  SERVED_N="$(served_count)"
  # Complete when the DB has rows and serving has caught up to them.
  if [ "${PERSISTED_N:-0}" -gt 0 ] && [ "${SERVED_N:-0}" -ge "${PERSISTED_N:-0}" ]; then
    break
  fi
  echo "   serving ${SERVED_N}/${PERSISTED_N} models (waiting for the set to converge)…"
  tg_sleep 5
done
if [ "${PERSISTED_N:-0}" -le 0 ] || [ "${SERVED_N:-0}" -lt "${PERSISTED_N:-0}" ]; then
  echo "!! model set did not fully serve within the bounded wait (persisted=${PERSISTED_N} served=${SERVED_N})."
  if [ "${PERSISTED_N:-0}" -le 0 ]; then
    echo "   No DB rows — registration did not persist; review the WARNING lines above (#13)."
  else
    echo "   DB has ${PERSISTED_N} rows but only ${SERVED_N} serve — the gateway is still loading (post-mint redeploy?),"
    echo "   or a store_model_in_db problem (#13). Do NOT hand off a partial model set (Codex may be among the missing)."
  fi
  FAILS=$((FAILS+1))
else
  echo "==> all $SERVED_N models serving on /v1/models (complete):"
  tg_curl "Authorization: Bearer" "$LITELLM_MASTER_KEY" -s "$LITELLM_URL/v1/models" \
    | python3 -c "import sys,json;[print('   -',m['id']) for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true
fi
fi

if [ -n "$BEDROCK_ROLE_ARN" ]; then
  cat <<EOF

Cross-account note: bedrock-runtime models (Claude/gpt-oss) are registered under
the "${PREFIX}" prefix and AssumeRole into $BEDROCK_ROLE_ARN — ensure the gateway
task role may sts:AssumeRole it and that role trusts the gateway (with external id).
Codex/Mantle uses the bearer key (above), not AssumeRole.
EOF
fi

[ "$WIZARD" = "1" ] && echo "==> wizard: deleted $DEL_N, registered $REG_N, serving $SERVED_N/$PERSISTED_N."

if [ "$FAILS" -gt 0 ]; then
  echo ""
  echo "!! register-models finished with $FAILS discovery warning(s) — the model set"
  echo "   may be INCOMPLETE. Review the WARNING lines above before handoff."
  exit 2
fi
echo "==> register-models complete (no discovery warnings)."
