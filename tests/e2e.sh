#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&B||C idiom intentional; curl args single-quoted on purpose
# End-to-end test: exercise the dev container against a DEPLOYED gateway and
# verify per-user governance works through the real front door.
#
# It is environment-agnostic — the gateway URL and master key are read from this
# repo's Terraform outputs (no hardcoded account/DNS). When CloudFront is enabled
# (enable_cloudfront=true) it drives the CloudFront URL and also asserts the ALB
# is not reachable directly (origin lock); otherwise it uses the ALB URL.
#
# Steps:
#   1. Resolve gateway URL (cloudfront_url -> alb_url) + master key from tf outputs.
#   2. (CloudFront on) assert direct-to-ALB is blocked.
#   3. Mint a throwaway per-user virtual key (small budget + allowed models).
#   4. Run Claude AND Codex INSIDE the dev container against the gateway.
#   5. Verify both responded and that per-user spend accrued. Clean up the key.
#
#   AWS_PROFILE=<profile> ./tests/e2e.sh <env>
#
# Env overrides: GATEWAY_URL, TEST_USER, CLAUDE_MODEL, CODEX_MODEL.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1                 # repo root
REPO_ROOT="$(pwd)"
# Pure denial classifier + the per-case expected-class regexes (single source of
# truth, unit-tested by tests/classify.test.sh). (#32)
# shellcheck source=tests/lib-classify.sh
. "$REPO_ROOT/tests/lib-classify.sh"

ENV="${1:-}"
[ -n "$ENV" ] || { echo "usage: AWS_PROFILE=<profile> ./tests/e2e.sh <env>"; exit 1; }
: "${AWS_PROFILE:?set AWS_PROFILE (selects the target AWS account)}"

# Reuse the deploy tooling for workspace-verified Terraform output reads.
# lib.sh's tg_init expects to run from deploy/ (workspace state lives there).
cd deploy || { echo "ERROR: deploy/ not found"; exit 1; }
# shellcheck source=/dev/null
. ./lib.sh
tg_init "$ENV"                                     # sets ENV/REGION, selects+verifies workspace
# lib.sh enables `set -e`; this script uses explicit `|| no ...` idioms and captures
# expected-nonzero container commands, so a stray errexit would abort before the
# error-first/cleanup logic. Disable it here. (#30)
set +e

TEST_USER="${TEST_USER:-e2e-test@example.com}"
CLAUDE_MODEL="${CLAUDE_MODEL:-AUTO}"   # AUTO = pick a served scoped name from /v1/models (#20)
# Codex sends the CANONICAL Mantle ID and speaks the Responses API (#30). Default
# to a canonical openai.gpt-* ID; the key allowlist and request below use it verbatim.
CODEX_MODEL="${CODEX_MODEL:-openai.gpt-5.5}"

pass=0; fail=0
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }

# 1. resolve gateway URL: prefer CloudFront (clients use it; ALB 403s direct).
CF_ENABLED="$(tf_output cloudfront_enabled 2>/dev/null || echo false)"
if [ -n "${GATEWAY_URL:-}" ]; then
  GW="$GATEWAY_URL"
elif [ "$CF_ENABLED" = "true" ]; then
  GW="$(tf_output cloudfront_url)"
else
  GW="$(tf_output alb_url)"
fi
ALB_URL="$(tf_output alb_url 2>/dev/null || true)"
MK_ARN="$(tf_output master_key_secret_arn)"
MK="$(aws secretsmanager get-secret-value --secret-id "$MK_ARN" --query SecretString --output text 2>/dev/null)"
cd "$REPO_ROOT" || exit 1

echo "== e2e: env=$ENV  gateway=$GW  cloudfront=$CF_ENABLED  user=$TEST_USER =="
[ -n "$MK" ] && ok "got master key" || { no "master key"; exit 1; }
auth=(-H "Authorization: Bearer $MK" -H "Content-Type: application/json")

# 1b. Claude scope coverage (#20): assert BOTH global/ and us/ scope-prefixed
# Claude names are served, and select one served scoped alias to exercise. Falls back to any
# Claude name if scoped ones aren't present (older deployment).
MODELS_JSON="$(curl -s "$GW/v1/models" "${auth[@]}" 2>/dev/null)"
GLOBAL_CLAUDE="$(printf '%s' "$MODELS_JSON" | python3 -c "import sys,json;print(next((m['id'] for m in json.load(sys.stdin).get('data',[]) if m['id'].startswith('global/claude')),''))" 2>/dev/null)"
US_CLAUDE="$(printf '%s' "$MODELS_JSON" | python3 -c "import sys,json;print(next((m['id'] for m in json.load(sys.stdin).get('data',[]) if m['id'].startswith('us/claude')),''))" 2>/dev/null)"
if [ -n "$GLOBAL_CLAUDE" ] && [ -n "$US_CLAUDE" ]; then
  ok "both Claude scopes served ($GLOBAL_CLAUDE + $US_CLAUDE)"
elif [ -n "$GLOBAL_CLAUDE$US_CLAUDE" ]; then
  no "only one Claude scope served (global='$GLOBAL_CLAUDE' us='$US_CLAUDE') — expected both (#20)"
fi
# 1c. Claude canonical inferenceProfileId names served additively (#33): the exact
# global.anthropic.* / us.anthropic.* ids (or <TENANT>/<id>) alongside friendly aliases.
CANON_CLAUDE="$(printf '%s' "$MODELS_JSON" | python3 -c "import sys,json;print(next((m['id'] for m in json.load(sys.stdin).get('data',[]) if '.anthropic.' in m['id'] and ('global.anthropic' in m['id'] or 'us.anthropic' in m['id'])),''))" 2>/dev/null)"
if [ -n "$CANON_CLAUDE" ]; then
  ok "canonical Claude inferenceProfileId served ($CANON_CLAUDE)"
else
  echo "  WARN no canonical *.anthropic.* Claude name served (older deployment pre-#33?)"
fi
# Prefer a served scoped name for the container run; keep env override if set.
[ "$CLAUDE_MODEL" = "AUTO" ] && CLAUDE_MODEL="${US_CLAUDE:-$GLOBAL_CLAUDE}"

# 2. origin lock: with CloudFront on, the ALB must reject direct traffic.
if [ "$CF_ENABLED" = "true" ] && [ -n "$ALB_URL" ]; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$ALB_URL/health/liveliness" 2>/dev/null || echo 000)"
  # A reachable, unlocked ALB answers 2xx. Anything else — connection dropped by
  # the SG (curl reports 000), or a WAF/other 4xx/5xx — means it's NOT directly
  # reachable, i.e. the origin lock holds.
  if printf '%s' "$CODE" | grep -qE '^2[0-9][0-9]$'; then
    no "direct-to-ALB NOT blocked (got $CODE — origin lock leaked)"
  else
    ok "direct-to-ALB blocked (origin lock; curl reported '$CODE')"
  fi
fi

# 3. mint a throwaway per-user key (small budget; reuses gateway governance)
KEY="$(curl -s "$GW/key/generate" "${auth[@]}" \
  -d "{\"user_id\":\"$TEST_USER\",\"key_alias\":\"e2e\",\"max_budget\":2,\"models\":[\"$CLAUDE_MODEL\",\"$CODEX_MODEL\"]}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('key',''))" 2>/dev/null)"
[ -n "$KEY" ] && ok "minted per-user key for $TEST_USER" || { no "key mint"; exit 1; }
# The credential/.env/compose-volume cleanup EXIT trap is installed just below,
# once $COMPOSE is defined (it revokes $KEY, removes .env, and tears down volumes).

# 4. build the container .env and run Claude + Codex INSIDE the dev container
cat > devcontainer/.env <<EOF
GATEWAY_URL=$GW
LITELLM_KEY=$KEY
CLAUDE_MODEL=$CLAUDE_MODEL
CLAUDE_FAST_MODEL=${CLAUDE_MODEL}
CODEX_MODEL=$CODEX_MODEL
EOF
# Fresh-home isolation (#32): a unique compose PROJECT per run gives fresh named
# home volumes (claude-home/codex-home) so prior client state can't satisfy this
# qualification. Torn down (with volumes) in the EXIT trap below.
COMPOSE_PROJECT="tgllmw-e2e-$$"
COMPOSE=(docker compose -p "$COMPOSE_PROJECT" -f devcontainer/docker-compose.yml)
# Extend the existing EXIT trap (key revoke + .env rm) with compose volume teardown.
# Intentional expand-now: $GW/$MK/$KEY/$COMPOSE/$PWD are already set here. (SC2064)
# shellcheck disable=SC2064
trap "curl -s '$GW/key/delete' -H 'Authorization: Bearer $MK' -H 'Content-Type: application/json' -d '{\"keys\":[\"$KEY\"]}' >/dev/null 2>&1 || true; rm -f '$PWD/devcontainer/.env'; ${COMPOSE[*]} down -v >/dev/null 2>&1 || true" EXIT
"${COMPOSE[@]}" build >/dev/null 2>&1 && ok "container image built" || no "container build"

run_in_container() { "${COMPOSE[@]}" run --rm -T dev bash -lc "$1" 2>/dev/null; }

echo "== Claude raw /v1/messages probe (lower-level signal) =="
CL="$(run_in_container 'curl -s -m 60 "$ANTHROPIC_BASE_URL/v1/messages" -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" -d "{\"model\":\"$ANTHROPIC_MODEL\",\"max_tokens\":40,\"messages\":[{\"role\":\"user\",\"content\":\"reply: claude in container works\"}]}"')"
echo "$CL" | python3 -c "import sys,json;sys.exit(0 if 'content' in json.load(sys.stdin) else 1)" 2>/dev/null \
  && ok "raw /v1/messages probe ok" || echo "  WARN raw /v1/messages probe failed: $(echo "$CL" | tail -c 160)"

echo "== real Claude Code CLI inside container (published config, Messages path, #32) =="
# BF (#32): exercise the ACTUAL Claude Code CLI with only the entrypoint-written
# env (ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL = published dev path), assert the FINAL
# TEXT (not a transcript grep), and fail loudly on any error/nonzero. Rolling/invalid
# auth is a WARN. Uses -p (print) + JSON output so we read the final result field.
CLCLI="$(run_in_container '
  set -o pipefail
  if claude -p --output-format json "Reply with exactly: CLAUDE_E2E_OK" >/tmp/cl.json 2>/tmp/cl.err; then st=0; else st=$?; fi
  echo "EXIT=$st"
  echo "RES_B64=$(python3 -c "import json,sys;sys.stdout.write(json.load(open(\"/tmp/cl.json\")).get(\"result\",\"\"))" 2>/dev/null | base64 -w0)"
  echo "ERR_B64=$(tail -c 400 /tmp/cl.err | base64 -w0)"
')"
CL_EXIT="$(printf '%s' "$CLCLI" | sed -n 's/^EXIT=//p' | head -1)"
CL_RES_B64="$(printf '%s' "$CLCLI" | sed -n 's/^RES_B64=//p' | head -1)"
CL_RES="$(printf '%s' "$CL_RES_B64" | base64 -d 2>/dev/null)"
CL_ERRT="$(printf '%s' "$CLCLI" | sed -n 's/^ERR_B64=//p' | head -1 | base64 -d 2>/dev/null)"
# EXACT-content comparison: compare base64 of the expected string to the received
# base64 — byte-for-byte, no whitespace stripping ( ' CLAUDE_E2E_OK ' must FAIL). (#30/#32)
CL_EXPECT_B64="$(printf '%s' 'CLAUDE_E2E_OK' | base64 -w0)"
if printf '%s' "$CL_ERRT $CL_RES" | grep -qiE 'model_access_denied|not allowed to access model'; then
  no "Claude Code CLI: model $CLAUDE_MODEL denied by key policy (#32): $(printf '%s' "$CL_ERRT" | tail -c 200)"
elif printf '%s' "$CL_ERRT" | grep -qiE 'invalid.?api.?key|authentication|401|unauthorized|expired'; then
  echo "  WARN Claude Code CLI auth inconclusive (key may be rolling): $(printf '%s' "$CL_ERRT" | tail -c 160)"
elif [ "${CL_EXIT:-1}" != "0" ]; then
  no "Claude Code CLI exited nonzero ($CL_EXIT): $(printf '%s' "$CL_ERRT" | tail -c 200)"
elif [ "$CL_RES_B64" = "$CL_EXPECT_B64" ]; then
  ok "real Claude Code CLI final result == CLAUDE_E2E_OK exactly ($CLAUDE_MODEL, Messages path)"
else
  no "Claude Code CLI final result not EXACTLY 'CLAUDE_E2E_OK' (got: $(printf '%s' "$CL_RES" | tail -c 120))"
fi

# Low-level probe (kept as a fast, separate signal): canonical ID on /v1/responses.
CX="$(run_in_container 'curl -s -m 60 "$GATEWAY_URL/v1/responses" -H "Authorization: Bearer $LITELLM_KEY" -H "Content-Type: application/json" -d "{\"model\":\"'"$CODEX_MODEL"'\",\"input\":\"reply: codex works\"}"')"
if echo "$CX" | grep -qi 'model_access_denied\|not allowed to access model'; then
  no "Codex canonical model $CODEX_MODEL denied by key policy (#30 regression): $(echo "$CX" | tail -c 160)"
elif echo "$CX" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if ('output' in d or 'output_text' in d) else 1)" 2>/dev/null; then
  ok "raw /v1/responses probe ok ($CODEX_MODEL)"
else
  echo "  WARN raw /v1/responses probe failed (Bedrock key may be rolling): $(echo "$CX" | tail -c 160)"
fi

echo "== real Codex CLI inside container (published config + generated catalog, #30) =="
# BF2: exercise the ACTUAL Codex CLI with only the entrypoint-generated config +
# version-matched catalog (docs/client-setup.md path). This is the only check that
# surfaces the additional_tools -> Mantle 400. We assert on the FINAL MESSAGE file
# (--output-last-message), NOT a transcript grep (Codex echoes the prompt, which
# false-passes). Errors and a nonzero exit are checked BEFORE content; only a
# rolling Bedrock key is a WARN. The entrypoint fails closed if the catalog can't
# be generated, so reaching Codex at all means the documented catalog is loaded.
CX_OUT="$(run_in_container '
  set -o pipefail
  out=/tmp/codex_last.txt; : > "$out"
  if codex exec --skip-git-repo-check --output-last-message "$out" \
       "Reply with exactly: CODEX_E2E_OK" >/tmp/codex_full.log 2>&1; then
    st=0; else st=$?; fi
  # base64 transport avoids delimiter bleed when the final message has no trailing
  # newline (#30 parser false-fail: cat + inline delimiter merged onto one line).
  echo "EXIT=$st"
  echo "LAST_B64=$(base64 -w0 < "$out")"
  echo "ERR_B64=$(tail -c 400 /tmp/codex_full.log | base64 -w0)"
')"
CX_EXIT="$(printf '%s' "$CX_OUT" | sed -n 's/^EXIT=//p' | head -1)"
CX_LAST_B64="$(printf '%s' "$CX_OUT" | sed -n 's/^LAST_B64=//p' | head -1)"
CX_LAST="$(printf '%s' "$CX_LAST_B64" | base64 -d 2>/dev/null)"
CX_ERR="$(printf '%s' "$CX_OUT" | sed -n 's/^ERR_B64=//p' | head -1 | base64 -d 2>/dev/null)"
# EXACT-content match: accept the expected string with at most a single trailing
# newline (a transport artifact of --output-last-message), but NOT embedded/leading
# whitespace ('CODEX _E2E_OK' / ' CODEX_E2E_OK ' must FAIL). Compare base64 forms. (#30)
CX_EXPECT_B64="$(printf '%s' 'CODEX_E2E_OK' | base64 -w0)"
CX_EXPECT_B64_NL="$(printf '%s\n' 'CODEX_E2E_OK' | base64 -w0)"
if printf '%s' "$CX_ERR $CX_LAST" | grep -qiE 'model_access_denied|not allowed to access model'; then
  no "Codex CLI: canonical model denied by key policy (#30 regression): $(printf '%s' "$CX_ERR" | tail -c 200)"
elif printf '%s' "$CX_ERR $CX_LAST" | grep -qiE 'additional_tools|did not match any expected variant|missing field .models|failed to parse model_catalog_json'; then
  no "Codex CLI: catalog/additional_tools incompatibility (#30 BF1/BF2): $(printf '%s' "$CX_ERR" | tail -c 200)"
elif printf '%s' "$CX_ERR $CX_LAST" | grep -qiE 'invalid_api_key|api key|expired|bearer'; then
  echo "  WARN Codex CLI: Bedrock key may be rolling — inconclusive: $(printf '%s' "$CX_ERR" | tail -c 160)"
elif [ "${CX_EXIT:-1}" != "0" ]; then
  no "Codex CLI exited nonzero ($CX_EXIT): $(printf '%s' "$CX_ERR" | tail -c 200)"
elif [ "$CX_LAST_B64" = "$CX_EXPECT_B64" ] || [ "$CX_LAST_B64" = "$CX_EXPECT_B64_NL" ]; then
  ok "real Codex CLI final message == CODEX_E2E_OK exactly ($CODEX_MODEL, Responses + catalog)"
else
  no "Codex CLI final message not EXACTLY 'CODEX_E2E_OK' (got: $(printf '%s' "$CX_LAST" | tail -c 120))"
fi

# 4c. repeat-container-run regression (#30): a SECOND container run must not
# self-destruct the persisted catalog (entrypoint regenerates atomically). Assert
# the catalog is present + nonempty and the config still points at it after re-entry.
RERUN="$(run_in_container '
  test -s "$HOME/.codex/gateway-models.json" \
    && python3 -c "import json,sys;json.load(open(\"$HOME/.codex/gateway-models.json\"))" \
    && grep -q "^model_catalog_json" "$HOME/.codex/config.toml" \
    && echo RERUN_OK || echo RERUN_BAD
')"
printf '%s' "$RERUN" | grep -q 'RERUN_OK' \
  && ok "second container run keeps a valid catalog + config (#30 no self-destruct)" \
  || no "second container run degraded the catalog/config (#30 regression): $(printf '%s' "$RERUN" | tail -c 120)"

# 5. verify per-user spend accrued, then clean up
sleep 12
# Look up spend WITHOUT putting the key in the URL (query strings land in the
# proxy access log / CloudWatch for 30d). Authenticate AS the key and read its
# own info from the response body. (#17)
INFO_JSON="$(curl -s "$GW/key/info" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" 2>/dev/null)"
SP="$(printf '%s' "$INFO_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('info',{}).get('spend',0))" 2>/dev/null)"
python3 -c "import sys;sys.exit(0 if float('${SP:-0}')>0 else 1)" 2>/dev/null \
  && ok "per-user spend accrued (\$$SP)" || no "no spend recorded (\$${SP:-?})"

# 5a. attribution (#32): assert /key/info shows the exact allowlisted model + user
# for THIS key (sanitized: alias/user only, never the token). Not just spend>0.
ATTR="$(printf '%s' "$INFO_JSON" | python3 -c '
import sys,json
want_model, want_user = sys.argv[1], sys.argv[2]
info = json.load(sys.stdin).get("info", {})
models = info.get("models") or []
ok = (want_model in models) and ((info.get("user_id") or "") == want_user) and ((info.get("key_alias") or "") == "e2e")
print("ATTR_OK" if ok else "ATTR_BAD")
' "$CLAUDE_MODEL" "$TEST_USER" 2>/dev/null)"
[ "$ATTR" = "ATTR_OK" ] \
  && ok "key attribution: allowlist contains selected model + correct user_id/alias" \
  || no "key attribution mismatch (#32): $ATTR"

# 5b. admin-route denial (#32): a per-user dev key must NOT read the admin-only
# spend logs. Expect a 401/403, never 200.
ADMIN_CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$GW/spend/logs" -H "Authorization: Bearer $KEY" 2>/dev/null || echo 000)"
case "$ADMIN_CODE" in
  401|403) ok "dev key denied admin /spend/logs (HTTP $ADMIN_CODE)" ;;
  200)     no "dev key READ admin /spend/logs (HTTP 200 — privilege boundary leak, #32)" ;;
  *)       echo "  WARN /spend/logs returned $ADMIN_CODE (inconclusive)" ;;
esac

# 5c. negative governance (#32) — these are EXPECTED-DENIAL assertions, not WARNs.
mreq() { # $1=key $2=model  -> prints the HTTP status of a minimal Messages call
  curl -s -o /dev/null -w '%{http_code}' -m 25 "$GW/v1/messages" \
    -H "Authorization: Bearer $1" -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
    -d "{\"model\":\"$2\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>/dev/null || echo 000
}
# Require a COMPLETED, DENIAL-SPECIFIC Claude Code error (#32). Layered corrections:
# - timeout exit 124 = inconclusive FAIL (client didn't finish; retries disabled to
#   force a fast structured error instead).
# - Override BOTH model selectors so a disallowed-model run can't fall back.
# - PASS requires ALL of: no success text; a COMPLETED structured error; the error
#   matches the EXPECTED per-case denial class ($4); and it is NOT a transport /
#   DNS / TLS / connectivity / generic-runtime error. `is_error:true` alone never
#   passes (QA: an unreachable-gateway transport error is is_error:true but is NOT a
#   governance denial). $1=key $2=model $3=label $4=expected-denial-regex.
claude_cli_denied() {
  local k="$1" m="$2" label="$3" want="$4" out
  out="$(run_in_container '
    export ANTHROPIC_AUTH_TOKEN="'"$k"'" ANTHROPIC_MODEL="'"$m"'" ANTHROPIC_SMALL_FAST_MODEL="'"$m"'"
    export CLAUDE_CODE_MAX_RETRIES=0 API_TIMEOUT_MS=20000
    if timeout 60 claude -p --output-format json "Reply with exactly: CLAUDE_E2E_OK" >/tmp/n.json 2>/tmp/n.err; then st=0; else st=$?; fi
    echo "EXIT=$st"
    echo "JSON_B64=$(base64 -w0 < /tmp/n.json 2>/dev/null)"
    echo "ERR_B64=$(base64 -w0 < /tmp/n.err 2>/dev/null)"
  ')"
  local ex js er blob is_err
  ex="$(printf '%s' "$out" | sed -n 's/^EXIT=//p' | head -1)"
  js="$(printf '%s' "$out" | sed -n 's/^JSON_B64=//p' | head -1 | base64 -d 2>/dev/null)"
  er="$(printf '%s' "$out" | sed -n 's/^ERR_B64=//p' | head -1 | base64 -d 2>/dev/null)"
  blob="$js $er"
  is_err="$(printf '%s' "$js" | python3 -c 'import sys,json
try: d=json.load(sys.stdin); print("1" if (isinstance(d,dict) and (d.get("is_error") is True or str(d.get("subtype","")).startswith("error"))) else "0")
except Exception: print("0")' 2>/dev/null)"
  # Delegate the decision to the pure, unit-tested classifier (tests/lib-classify.sh).
  local verdict; verdict="$(classify_denial "$blob" "$is_err" "${ex:-1}" "$want")"
  if [ "${verdict%% *}" = "PASS" ]; then
    ok "Claude Code CLI denied under $label (${verdict#PASS }, class /$want/, exit $ex; #32)"
  else
    no "Claude Code CLI under $label NOT a valid denial (${verdict#FAIL }, exit $ex; #32): $(printf '%s' "$blob" | tail -c 140)"
  fi
}
# invalid key -> 401 (raw), then the same through the real Claude Code CLI (#32)
INVALID_KEY="sk-invalid-$RANDOM-nonexistent"
INVCODE="$(mreq "$INVALID_KEY" "$CLAUDE_MODEL")"
[ "$INVCODE" = "401" ] && ok "invalid key denied (HTTP 401)" || no "invalid key not 401 (got $INVCODE, #32)"
claude_cli_denied "$INVALID_KEY" "$CLAUDE_MODEL" "invalid key" "$CLASS_INVALID_KEY"
# disallowed model -> 403: a served Claude name NOT in this key's allowlist.
DISALLOW="$(printf '%s' "$MODELS_JSON" | python3 -c "import sys,json;a='$CLAUDE_MODEL';print(next((m['id'] for m in json.load(sys.stdin).get('data',[]) if 'claude' in m['id'] and m['id']!=a),''))" 2>/dev/null)"
if [ -n "$DISALLOW" ]; then
  DISCODE="$(mreq "$KEY" "$DISALLOW")"
  case "$DISCODE" in
    403) ok "disallowed Claude model '$DISALLOW' denied (HTTP 403)"
         # same denial through the REAL Claude Code CLI (developer outcome).
         claude_cli_denied "$KEY" "$DISALLOW" "disallowed model" "$CLASS_DISALLOWED_MODEL" ;;
    200) no "disallowed Claude model '$DISALLOW' was ALLOWED (HTTP 200 — allowlist leak, #32)" ;;
    *)   echo "  WARN disallowed-model check returned $DISCODE (inconclusive)" ;;
  esac
else
  echo "  WARN no second Claude model served to test disallowed-model denial"
fi
# over-budget denial (#32): lower this key's budget below its accrued spend, then
# assert the next request is rejected. Poll for the budget cache to settle.
curl -s "$GW/key/update" "${auth[@]}" -d "{\"key\":\"$KEY\",\"max_budget\":0.0000001}" >/dev/null 2>&1 || true
BUDCODE=000
for _ in $(seq 1 30); do
  BUDCODE="$(mreq "$KEY" "$CLAUDE_MODEL")"
  [ "$BUDCODE" = "429" ] || [ "$BUDCODE" = "400" ] || [ "$BUDCODE" = "403" ] && break
  sleep 3
done
case "$BUDCODE" in
  429|400|403) ok "over-budget request denied (HTTP $BUDCODE)"
               # raw denial confirmed → prove the developer outcome via the CLI too.
               claude_cli_denied "$KEY" "$CLAUDE_MODEL" "over-budget key" "$CLASS_OVER_BUDGET" ;;
  200)         no "over-budget request still ALLOWED (HTTP 200 — budget not enforced, #32)" ;;
  *)           echo "  WARN over-budget check returned $BUDCODE (inconclusive)" ;;
esac

# revoked-key denial (#32): delete the key, then POLL to a documented timeout
# (revocation is eventually-consistent — QA observed denial at ~63s, not 3s).
# This also cleans up $KEY (the EXIT trap's delete becomes a no-op).
curl -s "$GW/key/delete" "${auth[@]}" -d "{\"keys\":[\"$KEY\"]}" >/dev/null 2>&1 || true
REVCODE=000
for _ in $(seq 1 40); do          # up to ~120s (cache window observed ~63s)
  REVCODE="$(mreq "$KEY" "$CLAUDE_MODEL")"
  [ "$REVCODE" = "401" ] || [ "$REVCODE" = "403" ] && break
  sleep 3
done
case "$REVCODE" in
  401|403) ok "revoked key eventually denied (HTTP $REVCODE)"
           # raw revocation confirmed propagated → prove it through the CLI too.
           claude_cli_denied "$KEY" "$CLAUDE_MODEL" "revoked key" "$CLASS_REVOKED_KEY" ;;
  200)     no "revoked key still ALLOWED after ~120s (revocation not enforced, #32)" ;;
  *)       echo "  WARN revoked-key check returned $REVCODE (inconclusive)" ;;
esac
rm -f devcontainer/.env

echo ""
echo "== RESULT: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
