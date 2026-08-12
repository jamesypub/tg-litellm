#!/usr/bin/env bash
# Offline transition tests for the #52/#53 readiness fixes in register-models.sh.
# These prove the retry/poll logic self-heals the exact fresh-account states QA
# cannot reach on a non-fresh stage account (edge 502 before routing is ready; a
# zero /v1/models window right after registration). No AWS/network: aws + curl are
# stubbed, and the gateway is driven through scripted state transitions via a
# counter file so the failure states are deterministic.
#
#   ./tests/register-models-readiness.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd)"
pass=0; fail=0
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }

# Instant waits: drive the retry/poll transitions with no real-time sleeps.
export TG_SLEEP_CMD=:

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
export TG_STATE="$WORK/state"; mkdir -p "$TG_STATE"

# --- aws stub: only the calls register-models.sh makes before the gateway phase ---
cat > "$BIN/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *sts\ get-caller-identity*) echo "000000000000" ;;
  *list-inference-profiles*global.anthropic*) printf 'global.anthropic.claude-opus-4-8\n' ;;
  *list-inference-profiles*us.anthropic*)     printf 'us.anthropic.claude-opus-4-8\n' ;;
  *list-foundation-models*)                   printf '\n' ;;   # no gpt-oss
  *) echo "" ;;
esac
STUB

# --- curl stub: emulates the gateway with SCRIPTED readiness transitions. ---
# MODEL_NEW_502_UNTIL: /model/new returns edge 502 until this many calls have
#   happened (then 200 with a model_id) — the #52 routing-gap transition.
# V1MODELS_ZERO_UNTIL: /v1/models returns an EMPTY data[] until this many polls
#   have happened (then a populated list) — the #53 visibility-lag transition.
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
S="$TG_STATE"
url=""; post=0
for a in "$@"; do
  case "$a" in
    http*|https*) url="$a" ;;
    -X) post=1 ;;
  esac
  [ "$a" = "POST" ] && post=1
done
bump(){ local f="$S/$1"; local n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"; echo "$n"; }
case "$url" in
  *githubusercontent*) echo '{}' ;;                        # price map (curl -o handles file)
  */model/new*)
      n="$(bump model_new)"
      if [ "$n" -le "${MODEL_NEW_502_UNTIL:-0}" ]; then
        printf '\n502'                                     # edge 502 (no JSON body), -w appends status
      else
        printf '{"model_id":"m-%s"}\n200' "$n"
      fi ;;
  # Persisted set: PERSISTED_TOTAL rows (default 3). This is what serving must reach.
  */model/info*)
      tot="${PERSISTED_TOTAL:-3}"
      python3 -c "import json;print(json.dumps({'data':[{'model_name':'m%d'%i} for i in range($tot)]}))" ;;
  # Served set: empty for the first V1MODELS_ZERO_UNTIL polls, then PARTIAL
  # (V1MODELS_PARTIAL_N rows) for the next V1MODELS_PARTIAL_UNTIL polls, then the
  # COMPLETE PERSISTED_TOTAL rows — models the 40/73 -> 73/73 convergence (#53/#62).
  */v1/models*)
      n="$(bump v1models)"; tot="${PERSISTED_TOTAL:-3}"
      if [ "$n" -le "${V1MODELS_ZERO_UNTIL:-0}" ]; then
        echo '{"data":[]}'
      elif [ "$n" -le "${V1MODELS_PARTIAL_UNTIL:-0}" ]; then
        python3 -c "import json;print(json.dumps({'data':[{'id':'m%d'%i} for i in range(${V1MODELS_PARTIAL_N:-1})]}))"
      else
        python3 -c "import json;print(json.dumps({'data':[{'id':'m%d'%i} for i in range($tot)]}))"
      fi ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export AWS_PROFILE=stub REGION=us-east-1 AWS_REGION=us-east-1
export LITELLM_URL="http://gw.example.test" LITELLM_MASTER_KEY="sk-master-stub"

run_register() { # runs register-models.sh with the current transition env, captures rc+log
  ( cd "$REPO/deploy" && ./register-models.sh ) >"$WORK/out" 2>&1; echo $?
}

echo "== #52: /model/new edge-502 self-heals via retry (no burned window) =="
: > "$TG_STATE/model_new"; : > "$TG_STATE/v1models"
# First 3 /model/new calls 502, then succeed; /v1/models visible immediately.
rc="$(MODEL_NEW_502_UNTIL=3 V1MODELS_ZERO_UNTIL=0 run_register)"
if [ "$rc" = 0 ]; then ok "#52 register-models exits 0 despite an initial 502 window"; else no "#52 exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -15; fi
grep -q '+ registered' "$WORK/out" && ok "#52 models registered after retry" || no "#52 no models registered after retry"

echo "== #53: zero /v1/models window self-heals via bounded poll =="
: > "$TG_STATE/model_new"; : > "$TG_STATE/v1models"
# /model/new fine; /v1/models empty for the first 2 polls, then the COMPLETE set.
rc="$(MODEL_NEW_502_UNTIL=0 V1MODELS_ZERO_UNTIL=2 PERSISTED_TOTAL=5 run_register)"
if [ "$rc" = 0 ]; then ok "#53 register-models exits 0 despite an initial zero-visibility window"; else no "#53 exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -15; fi
grep -qE 'all [0-9]+ models serving on /v1/models \(complete\)' "$WORK/out" && ok "#53 reports the complete served set after convergence" || no "#53 did not report a complete served set"
grep -q 'did not fully serve' "$WORK/out" && no "#53 falsely reported incomplete after convergence" || ok "#53 no false incomplete failure once converged"

echo "== #53/#62: PARTIAL served set (40/73-style) must NOT pass until complete =="
: > "$TG_STATE/model_new"; : > "$TG_STATE/v1models"
# persisted=5; /v1/models serves a PARTIAL 2 for the first 3 polls, then all 5.
# The gate must WAIT through the partial window and only succeed at completeness.
rc="$(MODEL_NEW_502_UNTIL=0 V1MODELS_ZERO_UNTIL=0 V1MODELS_PARTIAL_UNTIL=3 V1MODELS_PARTIAL_N=2 PERSISTED_TOTAL=5 run_register)"
if [ "$rc" = 0 ]; then ok "#62 register-models exits 0 only after the set converges 2/5 -> 5/5"; else no "#62 exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -20; fi
grep -qE 'serving 2/5 models' "$WORK/out" && ok "#62 gate observed + waited through the partial 2/5 snapshot" || no "#62 gate did not wait through the partial snapshot"
grep -qE 'all 5 models serving on /v1/models \(complete\)' "$WORK/out" && ok "#62 succeeds only at complete 5/5 (no partial pass)" || no "#62 did not confirm completeness"

echo "== #53/#62: incomplete set that NEVER converges fails closed =="
: > "$TG_STATE/model_new"; : > "$TG_STATE/v1models"
# persisted=5 but serving is stuck at a partial 2 forever (huge PARTIAL_UNTIL).
# Speed: TG_SLEEP_CMD=: already no-ops the poll waits, so 60 iterations are instant.
rc="$(MODEL_NEW_502_UNTIL=0 V1MODELS_ZERO_UNTIL=0 V1MODELS_PARTIAL_UNTIL=100000 V1MODELS_PARTIAL_N=2 PERSISTED_TOTAL=5 run_register)"
if [ "$rc" != 0 ]; then ok "#62 register-models fails closed (rc=$rc) when serving never reaches persisted"; else no "#62 should fail closed on a permanently-partial set"; fi
grep -qE 'did not fully serve' "$WORK/out" && ok "#62 reports the incomplete served<persisted set (no false success)" || no "#62 missing incomplete-set diagnostic"

echo ""
echo "== register-models readiness: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
