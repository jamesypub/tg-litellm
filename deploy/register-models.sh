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

# ---- 1. Claude: register BOTH global and us inference profiles under scope-
# prefixed names so operators/devs can pick routing scope explicitly (#20).
# alias = "<scope>/<model>" (e.g. global/claude-opus-4-8, us/claude-opus-4-8);
# value keeps the EXACT AWS inference-profile ID. No global-wins collapsing.
echo "==> discovering Claude models + inference profiles (via $DISCOVER_PROFILE)"
mapfile -t GLOBAL_PROFILES < <(AWS_PROFILE="$DISCOVER_PROFILE" aws bedrock list-inference-profiles --region "$REGION" \
  --query "inferenceProfileSummaries[?starts_with(inferenceProfileId,'global.anthropic')].inferenceProfileId" \
  --output text 2>/dev/null | tr '\t' '\n')
mapfile -t US_PROFILES < <(AWS_PROFILE="$DISCOVER_PROFILE" aws bedrock list-inference-profiles --region "$REGION" \
  --query "inferenceProfileSummaries[?starts_with(inferenceProfileId,'us.anthropic')].inferenceProfileId" \
  --output text 2>/dev/null | tr '\t' '\n')

declare -A CLAUDE   # "<scope>/<model>" -> exact inference-profile id
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
# bare alias per model, GLOBAL-preferred (us as fallback), pointing at the SAME
# profile. This is ADDITIVE — the explicit global/ and us/ scope names still exist
# for scope selection, so #20's no-global-wins-collapse contract holds for the
# scoped names; the bare name is a documented convenience that defaults to global.
declare -A BARE   # "claude-opus-4-8" -> exact inference-profile id (global preferred)
for alias in "${!CLAUDE[@]}"; do
  scope="${alias%%/*}"; model="${alias#*/}"
  # prefer a global-scoped profile for the bare name; only let us fill an empty slot
  if [ "$scope" = "global" ] || [ -z "${BARE[$model]:-}" ]; then
    BARE["$model"]="${CLAUDE[$alias]}"
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
probe_mantle() {
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
declare -a MANTLE_OK
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
    echo "   + registered $name"; EXISTING="$EXISTING
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
  pid="${BARE[$model]}"
  params="{\"model\":\"bedrock/$pid\",\"aws_region_name\":\"$REGION\"$XACCT}"
  reg "${PREFIX}${model}" "$params"
done

echo "==> registering OpenAI gpt-oss models (bedrock-runtime)"
for m in "${OSS[@]}"; do
  [ -z "$m" ] && continue
  alias="${m%%-1:0}"; alias="${alias#openai.}"
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

if [ -n "$BEDROCK_ROLE_ARN" ]; then
  cat <<EOF

Cross-account note: bedrock-runtime models (Claude/gpt-oss) are registered under
the "${PREFIX}" prefix and AssumeRole into $BEDROCK_ROLE_ARN — ensure the gateway
task role may sts:AssumeRole it and that role trusts the gateway (with external id).
Codex/Mantle uses the bearer key (above), not AssumeRole.
EOF
fi

if [ "$FAILS" -gt 0 ]; then
  echo ""
  echo "!! register-models finished with $FAILS discovery warning(s) — the model set"
  echo "   may be INCOMPLETE. Review the WARNING lines above before handoff."
  exit 2
fi
echo "==> register-models complete (no discovery warnings)."
