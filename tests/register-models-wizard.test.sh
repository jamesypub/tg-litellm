#!/usr/bin/env bash
# shellcheck disable=SC2015  # A&&ok||no idiom intentional (matches the other register-models tests)
# Offline tests for wizard mode (#95) in register-models.sh: delete phase, the
# confirm/DRY_RUN/SKIP_DELETE gates, additive-vs-clean, delete retry-on-5xx, and
# the SCOPE=us end-to-end bare-alias pin. No AWS/network: aws + curl are stubbed,
# same convention as tests/register-models-readiness.test.sh (mktemp -d bin,
# TG_SLEEP_CMD=: for instant retries). Run non-interactively (stdin </dev/null)
# so WIZARD_TTY is deterministically 0 regardless of how this file itself is run.
#
#   ./tests/register-models-wizard.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd)"
pass=0; fail=0
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }

export TG_SLEEP_CMD=:

# Guard the temp dir: without set -e a failed mktemp would leave WORK empty and
# BIN="/bin", and the stub writes below would clobber /bin/aws, /bin/curl. Abort
# loudly instead (Codex review of #95 blocker fixes).
WORK="$(mktemp -d)" || { echo "FATAL: mktemp -d failed"; exit 2; }
case "$WORK" in /|"") echo "FATAL: refusing to run with WORK='$WORK'"; exit 2 ;; esac
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
export TG_STATE="$WORK/state"; mkdir -p "$TG_STATE"

# --- aws stub: one global + one us Claude profile (mirrors the naming test's
# SCOPE=us/global fixture), no gpt-oss. A scenario can add extra profiles per
# scope via GLOBAL_PROFILES_EXTRA / US_PROFILES_EXTRA (space-separated, newline-
# joined into the list-inference-profiles output) without disturbing the default
# fixture the pre-existing 25 tests rely on.
cat > "$BIN/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *sts\ get-caller-identity*) echo "000000000000" ;;
  *list-inference-profiles*global.anthropic*)
      [ -n "${DISCOVERY_FAIL:-}" ] && { echo "AccessDeniedException: no bedrock" >&2; exit 254; }
      printf 'global.anthropic.claude-opus-4-8\n'
      for p in ${GLOBAL_PROFILES_EXTRA:-}; do printf '%s\n' "$p"; done ;;
  *list-inference-profiles*us.anthropic*)
      [ -n "${DISCOVERY_FAIL:-}" ] && { echo "AccessDeniedException: no bedrock" >&2; exit 254; }
      printf 'us.anthropic.claude-opus-4-8\n'
      for p in ${US_PROFILES_EXTRA:-}; do printf '%s\n' "$p"; done ;;
  *list-foundation-models*)                   printf '\n' ;;
  *) echo "" ;;
esac
STUB

# --- curl stub ---
# Knobs:
#   EXISTING_MODELS_JSON   initial /model/info data[] (JSON array of
#                          {"model_name":..., "model_info":{"id":...}}), default []
#   MODEL_NEW_502_UNTIL    /model/new returns edge 502 for this many calls first
#   MODEL_DELETE_502_UNTIL /model/delete returns edge 502 for this many calls first
# State written for assertions:
#   $TG_STATE/model_new_log      one request body per /model/new call
#   $TG_STATE/model_delete_log   one request body per /model/delete call
#   $TG_STATE/registered_names   model_name per successful (200) /model/new
#   $TG_STATE/deleted_ids        id per successful (200) /model/delete
printf '%s' "${EXISTING_MODELS_JSON:-[]}" > "$TG_STATE/existing_models.json"
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
S="$TG_STATE"
url=""; data=""; prev=""
for a in "$@"; do
  case "$a" in
    http*|https*) url="$a" ;;
  esac
  [ "$prev" = "-d" ] && data="$a"
  prev="$a"
done
bump(){ local f="$S/$1"; local n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"; echo "$n"; }
case "$url" in
  *githubusercontent*) echo '{}' ;;
  */model/new*)
      n="$(bump model_new)"
      printf '%s\n' "$data" >> "$S/model_new_log"
      if [ "$n" -le "${MODEL_NEW_502_UNTIL:-0}" ]; then
        printf '\n502'
      else
        name="$(printf '%s' "$data" | python3 -c "import sys,json;print(json.load(sys.stdin).get('model_name',''))" 2>/dev/null)"
        printf '%s\n' "$name" >> "$S/registered_names"
        printf '{"model_id":"reg-%s"}\n200' "$n"
      fi ;;
  */model/delete*)
      n="$(bump model_delete)"
      printf '%s\n' "$data" >> "$S/model_delete_log"
      if [ "$n" -le "${MODEL_DELETE_502_UNTIL:-0}" ]; then
        printf '\n502'
      else
        id="$(printf '%s' "$data" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null)"
        printf '%s\n' "$id" >> "$S/deleted_ids"
        printf '{}\n200'
      fi ;;
  */model/info*)
      python3 - "$S" <<'PY'
import json, os, sys
S = sys.argv[1]
data = json.load(open(f'{S}/existing_models.json'))
deleted = set()
if os.path.exists(f'{S}/deleted_ids'):
    deleted = set(open(f'{S}/deleted_ids').read().split())
data = [m for m in data if (m.get('model_info') or {}).get('id') not in deleted]
if os.path.exists(f'{S}/registered_names'):
    for i, name in enumerate(open(f'{S}/registered_names').read().splitlines()):
        if name:
            data.append({'model_name': name, 'model_info': {'id': f'reg-{i}'}})
print(json.dumps({'data': data}))
PY
      ;;
  */v1/models*)
      python3 - "$S" <<'PY'
import json, os, sys
S = sys.argv[1]
data = json.load(open(f'{S}/existing_models.json'))
deleted = set()
if os.path.exists(f'{S}/deleted_ids'):
    deleted = set(open(f'{S}/deleted_ids').read().split())
n = len([m for m in data if (m.get('model_info') or {}).get('id') not in deleted])
if os.path.exists(f'{S}/registered_names'):
    n += len([l for l in open(f'{S}/registered_names').read().splitlines() if l])
print(json.dumps({'data': [{'id': 'x%d' % i} for i in range(n)]}))
PY
      ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export AWS_PROFILE=stub REGION=us-east-1 AWS_REGION=us-east-1
export LITELLM_URL="http://gw.example.test" LITELLM_MASTER_KEY="sk-master-stub"

# Every scenario gets a clean state dir + fresh existing-models fixture.
reset_state() {
  rm -rf "$TG_STATE"; mkdir -p "$TG_STATE"
  printf '%s' "${1:-[]}" > "$TG_STATE/existing_models.json"
}

run_register() {   # runs register-models.sh non-interactively, captures rc
  ( cd "$REPO/deploy" && ./register-models.sh ) </dev/null >"$WORK/out" 2>&1; echo $?
}

# run_register_tty "<answers>": run with stdin attached to a real PTY (so the
# script's [ -t 0 ] is true and the interactive wizard prompts fire), feeding the
# newline-separated answers. Uses util-linux `script` to allocate the PTY. Answers
# are the raw lines the read prompts consume, in order.
run_register_tty() {
  local answers="$1"
  printf '%b' "$answers" | script -q -e -c "cd '$REPO/deploy' && ./register-models.sh" "$WORK/out" >/dev/null 2>&1
  local rc=$?
  # `script` records into $WORK/out (typescript); normalize CRs the PTY inserts.
  tr -d '\r' < "$WORK/out" > "$WORK/out.clean" && mv "$WORK/out.clean" "$WORK/out"
  echo "$rc"
}

# A Mantle probe stub the script can call via TG_MANTLE_PROBE_CMD. Echoes OK for
# any model listed (space-separated) in $MANTLE_OK_LIST, else NO — deterministic,
# no network. Written into BIN so it is on PATH.
cat > "$BIN/mantle-probe-stub" <<'STUB'
#!/usr/bin/env bash
want="$1"
for m in ${MANTLE_OK_LIST:-}; do [ "$m" = "$want" ] && { echo OK; exit 0; }; done
echo NO
STUB
chmod +x "$BIN/mantle-probe-stub"

echo "== #95 WIZARD=0: unaffected by wizard code (no wizard output, still registers) =="
reset_state
rc="$(run_register)"
if [ "$rc" = 0 ]; then ok "WIZARD=0 exits 0"; else no "WIZARD=0 exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -15; fi
grep -q '==> wizard' "$WORK/out" && no "WIZARD=0 unexpectedly printed wizard output" || ok "WIZARD=0 prints no wizard output"
grep -q '+ registered' "$WORK/out" && ok "WIZARD=0 still registers models" || no "WIZARD=0 registered nothing"

echo "== #95 WIZARD=1 WIZARD_MODE=clean WIZARD_CONFIRM=1: deletes existing then registers =="
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"old-1"}},{"model_name":"openai.gpt-5.4","model_info":{"id":"old-2"}}]'
rc="$(WIZARD=1 WIZARD_MODE=clean WIZARD_DELETE_SCOPE=both WIZARD_CONFIRM=1 run_register)"
if [ "$rc" = 0 ]; then ok "clean+confirm exits 0"; else no "clean+confirm exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -20; fi
[ "$(sort -u "$TG_STATE/deleted_ids" 2>/dev/null | wc -l)" -eq 2 ] && ok "clean+confirm deleted both existing rows" || no "clean+confirm deleted $(wc -l < "$TG_STATE/deleted_ids" 2>/dev/null || echo 0) row(s), expected 2"
grep -q 'wizard: deleted 2, registered' "$WORK/out" && ok "clean+confirm summary reports deleted=2" || no "clean+confirm summary missing deleted=2 (out: $(grep 'wizard:' "$WORK/out"))"

echo "== #95 WIZARD=1 WIZARD_MODE=clean, no WIZARD_CONFIRM (non-interactive): aborts closed, zero deletes =="
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"old-1"}}]'
rc="$(WIZARD=1 WIZARD_MODE=clean run_register)"
[ "$rc" = 1 ] && ok "missing WIZARD_CONFIRM aborts with rc=1" || no "missing WIZARD_CONFIRM rc=$rc (expected 1)"
[ -f "$TG_STATE/model_delete_log" ] && no "abort-closed still called /model/delete" || ok "abort-closed made zero /model/delete calls"
grep -q 'WIZARD_CONFIRM=1' "$WORK/out" && ok "abort message names WIZARD_CONFIRM=1 as the way forward" || no "abort message doesn't name WIZARD_CONFIRM=1"

echo "== #95 SKIP_DELETE=1: skips deletion, still registers, still requires Step-5 confirm =="
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"old-1"}}]'
rc="$(WIZARD=1 WIZARD_MODE=clean SKIP_DELETE=1 WIZARD_CONFIRM=1 run_register)"
if [ "$rc" = 0 ]; then ok "SKIP_DELETE=1 + WIZARD_CONFIRM exits 0"; else no "SKIP_DELETE=1 exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -15; fi
[ -f "$TG_STATE/model_delete_log" ] && no "SKIP_DELETE=1 still called /model/delete" || ok "SKIP_DELETE=1 made zero /model/delete calls"
grep -q 'SKIP_DELETE=1 — delete phase skipped' "$WORK/out" && ok "SKIP_DELETE=1 announces the skip" || no "SKIP_DELETE=1 missing skip announcement"
grep -q '==> wizard summary' "$WORK/out" && ok "SKIP_DELETE=1 still prints the Step-5 summary (blocker 4)" || no "SKIP_DELETE=1 skipped the Step-5 summary"

echo "== #95 QA blocker 4: SKIP_DELETE registering run WITHOUT confirm aborts closed =="
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"old-1"}}]'
rc="$(WIZARD=1 WIZARD_MODE=clean SKIP_DELETE=1 run_register)"
[ "$rc" = 1 ] && ok "SKIP_DELETE=1 without WIZARD_CONFIRM aborts rc=1 (would register)" || no "SKIP_DELETE=1 no-confirm rc=$rc (expected 1)"
[ -f "$TG_STATE/model_new_log" ] && no "SKIP_DELETE=1 no-confirm still registered a model" || ok "SKIP_DELETE=1 no-confirm registered nothing"

echo "== #95 DRY_RUN=1 clean mode: previews, zero real deletes, no confirm required =="
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"old-1"}}]'
rc="$(WIZARD=1 WIZARD_MODE=clean DRY_RUN=1 run_register)"
if [ "$rc" = 0 ]; then ok "DRY_RUN=1 exits 0 without WIZARD_CONFIRM"; else no "DRY_RUN=1 exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -15; fi
[ -f "$TG_STATE/model_delete_log" ] && no "DRY_RUN=1 still called /model/delete" || ok "DRY_RUN=1 made zero real /model/delete calls"
grep -q '\[dry-run\] delete' "$WORK/out" && ok "DRY_RUN=1 previews the delete candidate" || no "DRY_RUN=1 missing dry-run delete preview"

echo "== #95 WIZARD_MODE=additive: never calls delete even with stale rows present =="
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"old-1"}}]'
rc="$(WIZARD=1 WIZARD_MODE=additive WIZARD_CONFIRM=1 run_register)"
if [ "$rc" = 0 ]; then ok "additive mode exits 0"; else no "additive mode exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -15; fi
[ -f "$TG_STATE/model_delete_log" ] && no "additive mode still called /model/delete" || ok "additive mode made zero /model/delete calls"

echo "== #95 QA blocker 3: failed Claude discovery aborts BEFORE any delete (fail-closed) =="
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"old-1"}}]'
rc="$(WIZARD=1 WIZARD_MODE=clean WIZARD_DELETE_SCOPE=both WIZARD_CONFIRM=1 DISCOVERY_FAIL=1 run_register)"
[ "$rc" = 1 ] && ok "discovery failure aborts rc=1 (blocker 3)" || no "discovery failure rc=$rc (expected 1)"
[ -f "$TG_STATE/model_delete_log" ] && no "discovery failure still deleted a working row (fail-open!)" || ok "discovery failure deleted nothing (fail-closed)"
[ -f "$TG_STATE/model_new_log" ] && no "discovery failure still registered a model" || ok "discovery failure registered nothing"
grep -q 'discovery failed' "$WORK/out" && ok "discovery failure prints the abort reason" || no "discovery failure missing abort message"

echo "== #95 QA blocker 4: additive run WITHOUT confirm aborts before any /model/new =="
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"old-1"}}]'
rc="$(WIZARD=1 WIZARD_MODE=additive run_register)"
[ "$rc" = 1 ] && ok "additive no-confirm aborts rc=1 (Step 5 enforced, blocker 4)" || no "additive no-confirm rc=$rc (expected 1)"
[ -f "$TG_STATE/model_new_log" ] && no "additive no-confirm still wrote /model/new (Step 5 bypassed)" || ok "additive no-confirm registered nothing"
grep -q '==> wizard summary' "$WORK/out" && ok "additive no-confirm still printed the Step-5 summary" || no "additive no-confirm skipped the summary"
grep -q 'WIZARD_CONFIRM=1' "$WORK/out" && ok "additive no-confirm names WIZARD_CONFIRM=1 as the way forward" || no "additive no-confirm missing WIZARD_CONFIRM=1 hint"

echo "== #95 delete retry-on-edge-5xx self-heals =="
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"old-1"}}]'
rc="$(WIZARD=1 WIZARD_MODE=clean WIZARD_CONFIRM=1 MODEL_DELETE_502_UNTIL=2 run_register)"
if [ "$rc" = 0 ]; then ok "delete retry-on-502 self-heals (exits 0)"; else no "delete retry-on-502 exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -20; fi
grep -q '\- deleted global/claude-opus-4-8' "$WORK/out" && ok "delete retry-on-502 eventually deletes the row" || no "delete retry-on-502 never confirmed the delete"

echo "== #95 delete permanently failing (edge 5xx forever) increments FAILS -> non-zero exit =="
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"old-1"}}]'
rc="$(WIZARD=1 WIZARD_MODE=clean WIZARD_CONFIRM=1 MODEL_DELETE_502_UNTIL=100000 run_register)"
[ "$rc" != 0 ] && ok "permanently-failing delete fails closed (rc=$rc)" || no "permanently-failing delete should not exit 0"
grep -q 'FAILED delete' "$WORK/out" && ok "permanently-failing delete reports FAILED" || no "permanently-failing delete missing FAILED diagnostic"

echo "== #95 SCOPE=us end-to-end: bare alias points at the us-scoped profile id =="
reset_state
rc="$(WIZARD=1 WIZARD_MODE=additive SCOPE=us WIZARD_CONFIRM=1 run_register)"
if [ "$rc" = 0 ]; then ok "SCOPE=us end-to-end exits 0"; else no "SCOPE=us end-to-end exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -15; fi
# The bare alias "claude-opus-4-8" must carry the us.anthropic profile id, not global.
bare_body="$(grep '"model_name":"claude-opus-4-8"' "$TG_STATE/model_new_log" 2>/dev/null | tail -1)"
case "$bare_body" in
  *'bedrock/us.anthropic.claude-opus-4-8'*) ok "SCOPE=us pins the bare alias to the us-scoped profile id" ;;
  *) no "SCOPE=us bare alias body: ${bare_body:-<not found>}" ;;
esac
# Both scope-prefixed aliases must STILL be registered regardless of SCOPE (#20).
grep -q '"model_name":"global/claude-opus-4-8"' "$TG_STATE/model_new_log" && ok "SCOPE=us still registers global/claude-opus-4-8 (#20)" || no "SCOPE=us dropped the global/ scoped alias (#20 violation)"
grep -q '"model_name":"us/claude-opus-4-8"' "$TG_STATE/model_new_log" && ok "SCOPE=us still registers us/claude-opus-4-8 (#20)" || no "SCOPE=us dropped the us/ scoped alias (#20 violation)"

# ============================================================================
# #95 QA reruns: the four defects the shipped suite missed (defects 1-4).
# ============================================================================

echo "== #95 QA defect 1: invalid WIZARD_DELETE_SCOPE fails closed (no silent 'both') =="
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"old-1"}},{"model_name":"openai.gpt-5.4","model_info":{"id":"old-2"}}]'
rc="$(WIZARD=1 WIZARD_MODE=clean WIZARD_DELETE_SCOPE=bogus WIZARD_CONFIRM=1 run_register)"
[ "$rc" = 1 ] && ok "invalid WIZARD_DELETE_SCOPE aborts rc=1" || no "invalid WIZARD_DELETE_SCOPE rc=$rc (expected 1)"
[ -f "$TG_STATE/model_delete_log" ] && no "invalid WIZARD_DELETE_SCOPE still deleted something" || ok "invalid WIZARD_DELETE_SCOPE deleted nothing"
grep -q "WIZARD_DELETE_SCOPE='bogus' invalid" "$WORK/out" && ok "invalid WIZARD_DELETE_SCOPE names the bad value" || no "invalid WIZARD_DELETE_SCOPE missing diagnostic"

echo "== #95 QA defect 1: invalid SCOPE fails closed =="
reset_state
rc="$(WIZARD=1 WIZARD_MODE=additive SCOPE=bogus run_register)"
[ "$rc" = 1 ] && ok "invalid SCOPE aborts rc=1" || no "invalid SCOPE rc=$rc (expected 1)"
grep -q "SCOPE='bogus' invalid" "$WORK/out" && ok "invalid SCOPE names the bad value" || no "invalid SCOPE missing diagnostic"

echo "== #95 QA defect 1: TTY numeric answers map correctly (clean, claude-only, us) =="
# Answers in order: Step1 mode=2(clean), Step2 delete=1(claude), Step3 scope=1(us),
# Step4 review=Enter(accept), summary Proceed?=y. claude-only delete must remove
# ONLY the claude row and leave the mantle row (the old bug fell through to 'both').
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"c-1"}},{"model_name":"openai.gpt-5.4","model_info":{"id":"m-1"}}]'
rc="$(WIZARD=1 run_register_tty '2\n1\n1\n\ny\n')"
if [ "$rc" = 0 ]; then ok "TTY clean/claude/us walkthrough exits 0"; else no "TTY walkthrough exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -25; fi
grep -q '"id":"c-1"' "$TG_STATE/model_delete_log" 2>/dev/null && ok "TTY delete=1 deleted the claude row" || no "TTY delete=1 did not delete the claude row"
grep -q '"id":"m-1"' "$TG_STATE/model_delete_log" 2>/dev/null && no "TTY delete=1 wrongly deleted the mantle row (fell through to 'both')" || ok "TTY delete=1 left the mantle row intact (claude-only, not both)"
# scope=1 => us: bare alias must point at us.anthropic, and both scoped aliases still register (#20)
bare_body="$(grep '"model_name":"claude-opus-4-8"' "$TG_STATE/model_new_log" 2>/dev/null | tail -1)"
case "$bare_body" in *'bedrock/us.anthropic.claude-opus-4-8'*) ok "TTY scope=1 pinned bare alias to us-scoped id" ;; *) no "TTY scope=1 bare alias body: ${bare_body:-<not found>}" ;; esac

echo "== #95 QA defect 2: EOL/legacy models are NOT registered by default =="
# Discover an EOL (claude-sonnet-4), a legacy (claude-3-haiku), and the QA-required
# claude-3-5-haiku (dated form, exercises date-strip normalization) alongside opus.
reset_state
rc="$(WIZARD=1 WIZARD_MODE=additive WIZARD_CONFIRM=1 \
      GLOBAL_PROFILES_EXTRA='global.anthropic.claude-sonnet-4 global.anthropic.claude-3-haiku-20240307-v1:0 global.anthropic.claude-3-5-haiku-20241022-v1:0' \
      run_register)"
if [ "$rc" = 0 ]; then ok "EOL/legacy default run exits 0"; else no "EOL/legacy run exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -20; fi
grep -q '"model_name":"claude-opus-4-8"' "$TG_STATE/model_new_log" && ok "non-EOL claude-opus-4-8 still registers" || no "non-EOL model failed to register"
grep -q '"model_name":"claude-sonnet-4"' "$TG_STATE/model_new_log" && no "EOL claude-sonnet-4 registered (should be off by default)" || ok "EOL claude-sonnet-4 NOT registered by default"
grep -q '"model_name":"claude-3-haiku"' "$TG_STATE/model_new_log" && no "legacy claude-3-haiku registered (should be off by default)" || ok "legacy claude-3-haiku NOT registered by default"
# QA rerun blocker 1: claude-3-5-haiku must be off by default across ALL forms.
grep -q '"model_name":"claude-3-5-haiku"' "$TG_STATE/model_new_log" && no "claude-3-5-haiku bare registered (blocker 1: should be off)" || ok "claude-3-5-haiku bare NOT registered by default (blocker 1)"
grep -q 'anthropic.claude-3-5-haiku' "$TG_STATE/model_new_log" && no "claude-3-5-haiku leaked via canonical/scoped form (blocker 1)" || ok "claude-3-5-haiku off across every form (whole-model gate, blocker 1)"
# EOL/legacy also must not leak via their canonical/scoped forms (whole-model gate).
grep -q 'anthropic.claude-sonnet-4' "$TG_STATE/model_new_log" && no "EOL leaked via a canonical/scoped form" || ok "EOL leaks via no registration form (whole-model gate)"

echo "== #95 QA defect 2: WIZARD_INCLUDE can re-enable an EOL model (all forms) =="
reset_state
rc="$(WIZARD=1 WIZARD_MODE=additive WIZARD_CONFIRM=1 WIZARD_INCLUDE='claude-sonnet-4' \
      GLOBAL_PROFILES_EXTRA='global.anthropic.claude-sonnet-4' run_register)"
if [ "$rc" = 0 ]; then ok "INCLUDE=claude-sonnet-4 run exits 0"; else no "INCLUDE run exit $rc"; sed 's/^/       /' "$WORK/out" | tail -20; fi
grep -q '"model_name":"claude-sonnet-4"' "$TG_STATE/model_new_log" && ok "WIZARD_INCLUDE re-enables the EOL bare alias" || no "WIZARD_INCLUDE failed to re-enable EOL bare alias"
grep -q '"model_name":"global/claude-sonnet-4"' "$TG_STATE/model_new_log" && ok "WIZARD_INCLUDE re-enables the EOL scoped alias too (whole-model)" || no "WIZARD_INCLUDE did not re-enable the scoped form"

echo "== #95 QA defect 4: WIZARD_EXCLUDE deselects a WHOLE model (canonical+scoped+bare) =="
reset_state
rc="$(WIZARD=1 WIZARD_MODE=additive WIZARD_CONFIRM=1 WIZARD_EXCLUDE='claude-opus-4-8' run_register)"
if [ "$rc" = 0 ]; then ok "EXCLUDE whole-model run exits 0"; else no "EXCLUDE run exit $rc"; sed 's/^/       /' "$WORK/out" | tail -20; fi
grep -q '"model_name":"claude-opus-4-8"' "$TG_STATE/model_new_log" 2>/dev/null && no "EXCLUDE left the bare alias registered" || ok "EXCLUDE dropped the bare alias"
grep -q '"model_name":"global/claude-opus-4-8"' "$TG_STATE/model_new_log" 2>/dev/null && no "EXCLUDE left the scoped alias registered (defect 4)" || ok "EXCLUDE dropped the scoped alias too"
grep -q 'global.anthropic.claude-opus-4-8"' "$TG_STATE/model_new_log" 2>/dev/null && no "EXCLUDE left the canonical id registered (defect 4)" || ok "EXCLUDE dropped the canonical id too"
[ "$(wc -l < "$TG_STATE/model_new_log" 2>/dev/null || echo 0)" -eq 0 ] && ok "EXCLUDE of the only model registered nothing" || no "EXCLUDE still registered $(wc -l < "$TG_STATE/model_new_log") form(s)"

echo "== #95 QA defect 4: available Mantle model is deselectable via WIZARD_EXCLUDE =="
reset_state
rc="$(WIZARD=1 WIZARD_MODE=additive WIZARD_CONFIRM=1 TG_MANTLE_PROBE_CMD=mantle-probe-stub MANTLE_OK_LIST='openai.gpt-5.6-sol' \
      WIZARD_EXCLUDE='openai.gpt-5.6-sol' run_register)"
if [ "$rc" = 0 ]; then ok "Mantle-deselect run exits 0"; else no "Mantle-deselect run exit $rc"; sed 's/^/       /' "$WORK/out" | tail -20; fi
grep -q '"model_name":"openai.gpt-5.6-sol"' "$TG_STATE/model_new_log" && no "excluded Mantle model still registered (defect 4)" || ok "excluded Mantle model NOT registered"
grep -q '"model_name":"gpt-5-6-sol"' "$TG_STATE/model_new_log" && no "excluded Mantle legacy rewrite still registered" || ok "excluded Mantle legacy rewrite NOT registered"

echo "== #95 QA defect 4: an AVAILABLE Mantle model registers when NOT excluded (probe seam sanity) =="
reset_state
rc="$(WIZARD=1 WIZARD_MODE=additive WIZARD_CONFIRM=1 TG_MANTLE_PROBE_CMD=mantle-probe-stub MANTLE_OK_LIST='openai.gpt-5.6-sol' run_register)"
if [ "$rc" = 0 ]; then ok "Mantle-available run exits 0"; else no "Mantle-available run exit $rc"; sed 's/^/       /' "$WORK/out" | tail -20; fi
grep -q '"model_name":"openai.gpt-5.6-sol"' "$TG_STATE/model_new_log" && ok "available Mantle model registers by default" || no "available Mantle model did not register (probe seam broken?)"

echo "== #115 Issue 1: bare-alias scope prompt defaults to 'us' (Enter accepts us, not both) =="
# Answers: Step1 mode=2(clean), Step2 delete=1(claude), Step3 scope=Enter(default),
# Step4 review=Enter(accept), Proceed?=y. The default must resolve to us → the bare
# alias points at the us.anthropic profile (the old default was both → global).
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"c-1"}}]'
rc="$(WIZARD=1 run_register_tty '2\n1\n\n\ny\n')"
if [ "$rc" = 0 ]; then ok "scope-default TTY walkthrough exits 0"; else no "scope-default walkthrough exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -25; fi
bare_body="$(grep '"model_name":"claude-opus-4-8"' "$TG_STATE/model_new_log" 2>/dev/null | tail -1)"
case "$bare_body" in *'bedrock/us.anthropic.claude-opus-4-8'*) ok "scope default (Enter) pinned bare alias to us (#115 Issue 1)" ;; *) no "scope default did not pin us; bare alias body: ${bare_body:-<not found>}" ;; esac

echo "== #115 Issue 0: WIZARD_FAMILY=claude skips Mantle probe + registers no OpenAI rows =="
reset_state
rc="$(WIZARD=1 WIZARD_MODE=additive WIZARD_CONFIRM=1 WIZARD_FAMILY=claude \
      TG_MANTLE_PROBE_CMD=mantle-probe-stub MANTLE_OK_LIST='openai.gpt-5.6-sol' run_register)"
if [ "$rc" = 0 ]; then ok "Claude-only run exits 0"; else no "Claude-only run exit $rc"; sed 's/^/       /' "$WORK/out" | tail -20; fi
grep -q 'skipping Mantle' "$WORK/out" && ok "Claude-only announces the Mantle skip" || no "Claude-only missing Mantle-skip announcement"
grep -q 'probing Mantle' "$WORK/out" && no "Claude-only still probed Mantle" || ok "Claude-only did NOT probe Mantle"
grep -q '"model_name":"openai.gpt-5.6-sol"' "$TG_STATE/model_new_log" 2>/dev/null && no "Claude-only registered a Mantle model" || ok "Claude-only registered no Mantle model (even an available one)"
grep -q '"model_name":"claude-opus-4-8"' "$TG_STATE/model_new_log" 2>/dev/null && ok "Claude-only still registers Claude models" || no "Claude-only registered no Claude model"

echo "== #115 Issue 0: WIZARD_FAMILY=mantle skips Claude discovery + registers no Claude rows =="
reset_state
rc="$(WIZARD=1 WIZARD_MODE=additive WIZARD_CONFIRM=1 WIZARD_FAMILY=mantle \
      TG_MANTLE_PROBE_CMD=mantle-probe-stub MANTLE_OK_LIST='openai.gpt-5.6-sol' run_register)"
if [ "$rc" = 0 ]; then ok "Mantle-only run exits 0"; else no "Mantle-only run exit $rc"; sed 's/^/       /' "$WORK/out" | tail -20; fi
grep -q 'skipping Claude' "$WORK/out" && ok "Mantle-only announces the Claude skip" || no "Mantle-only missing Claude-skip announcement"
grep -q 'discovering Claude models' "$WORK/out" && no "Mantle-only still discovered Claude" || ok "Mantle-only did NOT discover Claude"
grep -q '"model_name":"claude-opus-4-8"' "$TG_STATE/model_new_log" 2>/dev/null && no "Mantle-only registered a Claude model" || ok "Mantle-only registered no Claude model"
grep -q '"model_name":"openai.gpt-5.6-sol"' "$TG_STATE/model_new_log" 2>/dev/null && ok "Mantle-only still registers the available Mantle model" || no "Mantle-only registered no Mantle model"

echo "== #115 Issue 0: invalid WIZARD_FAMILY fails closed (no silent 'both') =="
reset_state
rc="$(WIZARD=1 WIZARD_MODE=additive WIZARD_CONFIRM=1 WIZARD_FAMILY=bogus run_register)"
[ "$rc" = 1 ] && ok "invalid WIZARD_FAMILY aborts rc=1" || no "invalid WIZARD_FAMILY rc=$rc (expected 1)"
grep -q "WIZARD_FAMILY='bogus' invalid" "$WORK/out" && ok "invalid WIZARD_FAMILY names the bad value" || no "invalid WIZARD_FAMILY missing diagnostic"

echo "== #115 HIGH-2: explicitly-empty WIZARD_FAMILY='' fails closed (not silently promoted to 'both') =="
reset_state
rc="$(WIZARD=1 WIZARD_MODE=additive WIZARD_CONFIRM=1 WIZARD_FAMILY='' run_register)"
[ "$rc" = 1 ] && ok "empty WIZARD_FAMILY aborts rc=1 (parity with sibling axes)" || no "empty WIZARD_FAMILY rc=$rc (expected 1 — was it promoted to both?)"
grep -q "WIZARD_FAMILY='' invalid" "$WORK/out" && ok "empty WIZARD_FAMILY names the bad value" || no "empty WIZARD_FAMILY missing diagnostic"

echo "== #115 Issue 5: DRY_RUN relabels the /v1/models list as current-state, not the plan's outcome =="
reset_state '[{"model_name":"openai.gpt-5.6-sol","model_info":{"id":"pre-1"}},{"model_name":"GLM 5.2","model_info":{"id":"pre-2"}}]'
rc="$(WIZARD=1 WIZARD_MODE=additive WIZARD_FAMILY=claude DRY_RUN=1 run_register)"
if [ "$rc" = 0 ]; then ok "dry-run exits 0"; else no "dry-run exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -20; fi
grep -q 'this preview changed nothing' "$WORK/out" && ok "dry-run labels the served list as unchanged-by-preview" || no "dry-run missing the 'changed nothing' relabel"
grep -qE 'all [0-9]+ models serving on /v1/models \(complete\)' "$WORK/out" && no "dry-run still prints the misleading 'all N serving (complete)' outcome line" || ok "dry-run does NOT print the 'complete' outcome line"
[ -f "$TG_STATE/model_new_log" ] && no "dry-run actually registered something" || ok "dry-run registered nothing (preview only)"

echo "== #115 Issue 2: Step-5 summary redisplays the final selected model list + reworded confirm =="
# Step1 mode=2(clean), Step2 delete=1(claude), Step3 scope=Enter, Step4 review=Enter(accept),
# Proceed?=y. The summary must list the selected model(s) with [x] and the confirm
# prompt must name the count ("Proceed with these N model(s)?"), not a bare "Proceed?".
reset_state '[{"model_name":"global/claude-opus-4-8","model_info":{"id":"c-1"}}]'
rc="$(WIZARD=1 run_register_tty '2\n1\n\n\ny\n')"
if [ "$rc" = 0 ]; then ok "Issue 2 TTY walkthrough exits 0"; else no "Issue 2 walkthrough exit $rc (expected 0)"; sed 's/^/       /' "$WORK/out" | tail -25; fi
grep -qE 'selected models:[[:space:]]+[0-9]+' "$WORK/out" && ok "summary prints a selected-models count line" || no "summary missing the 'selected models:' count line"
grep -qE '^[[:space:]]+\[x\] claude-opus-4-8$' "$WORK/out" && ok "summary redisplays the selected model with [x]" || no "summary did not redisplay the selected model list"
grep -q 'Proceed with these' "$WORK/out" && ok "confirm prompt names the selected count (#115 Issue 2)" || no "confirm prompt still the bare 'Proceed?'"

echo ""
echo "== register-models wizard: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
