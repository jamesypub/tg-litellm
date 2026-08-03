#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&B||C idiom is intentional; reporters never fail
# Populate TEST data into a running LiteLLM gateway and exercise it.
#
# Separate from install/register-models — this creates throwaway teams, users,
# and virtual keys, then runs real Claude + Codex calls and checks that spend
# attributes per user and that an over-budget key is denied.
#
#   LITELLM_URL=http://<alb> LITELLM_MASTER_KEY=sk-... ./seed-test-data.sh
#
# Optional:
#   CLAUDE_MODEL=claude-opus-4-8   (a registered model name; default below)
#   CODEX_MODEL=gpt-5-5            (set empty to skip Codex tests)
#   PREFIX=test                   (name prefix for created teams/users)
#   CLEANUP=1                     (delete the test teams/keys at the end)
set -uo pipefail

GW="${LITELLM_URL:?set LITELLM_URL}"
MK="${LITELLM_MASTER_KEY:?set LITELLM_MASTER_KEY}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-8}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5-5}"
PFX="${PREFIX:-test}"
CLEANUP="${CLEANUP:-0}"
J="Content-Type: application/json"
# Secret-safe curl: bearer token via an owner-only --config file, never on argv (#50).
#   tg_curl "$TOKEN" <curl args...>
tg_curl() {
  local secret="$1"; shift
  local cfg rc=0; cfg="$(mktemp)"; chmod 600 "$cfg"
  trap 'rm -f "$cfg"' RETURN   # + explicit rm below: cleanup even on forced curl failure (#50)
  printf 'header = "Authorization: Bearer %s"\n' "$secret" > "$cfg"
  curl --config "$cfg" "$@" || rc=$?
  rm -f "$cfg"; return "$rc"
}
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

echo "== gateway: $GW =="
curl -sf "$GW/health/liveliness" >/dev/null 2>&1 && ok "gateway healthy" || { no "gateway unreachable"; exit 1; }

# ---- Team + two users with budgets ----
echo "== create team + users =="
TID=$(tg_curl "$MK" -s "$GW/team/new" -H "$J" \
  -d "{\"team_alias\":\"${PFX}-team\",\"max_budget\":10,\"team_member_budget\":5}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('team_id',''))" 2>/dev/null)
[ -n "$TID" ] && ok "team created ($TID)" || no "team create"

mkkey(){ tg_curl "$MK" -s "$GW/key/generate" -H "$J" \
  -d "{\"user_id\":\"$1\",\"team_id\":\"$TID\",\"max_budget\":$2,\"models\":[\"$CLAUDE_MODEL\"${CODEX_MODEL:+,\"$CODEX_MODEL\"}]}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('key',''))" 2>/dev/null; }
K1=$(mkkey "${PFX}-user1@example.com" 5)
K2=$(mkkey "${PFX}-user2@example.com" 5)
[ -n "$K1" ] && [ -n "$K2" ] && ok "two user keys minted" || no "key mint"

callm(){ # key model prompt -> prints OK/err
  tg_curl "$1" -s -m 60 "$GW/v1/chat/completions" -H "$J" \
    -d "{\"model\":\"$2\",\"messages\":[{\"role\":\"user\",\"content\":\"$3\"}]}"; }

# ---- Real model calls ----
echo "== real model calls =="
R=$(callm "$K1" "$CLAUDE_MODEL" "Say hello in 3 words.")
echo "$R" | python3 -c "import sys,json;sys.exit(0 if 'choices' in json.load(sys.stdin) else 1)" 2>/dev/null \
  && ok "Claude call ($CLAUDE_MODEL)" || no "Claude call: $(echo "$R" | head -c 120)"

if [ -n "$CODEX_MODEL" ]; then
  R=$(callm "$K2" "$CODEX_MODEL" "Write a python one-liner to reverse a string. Code only.")
  echo "$R" | python3 -c "import sys,json;sys.exit(0 if 'choices' in json.load(sys.stdin) else 1)" 2>/dev/null \
    && ok "Codex call ($CODEX_MODEL)" || no "Codex call (needs BEDROCK_API_KEY): $(echo "$R" | head -c 120)"
fi

# ---- Spend attribution ----
echo "== spend attribution (allow flush) =="
sleep 12
# Self-lookup authenticated AS the key — never put the key in the URL (query
# strings are logged to CloudWatch for 30d). (#17)
SP=$(tg_curl "$K1" -s "$GW/key/info" -H "Content-Type: application/json" | python3 -c "import sys,json;print(json.load(sys.stdin).get('info',{}).get('spend',0))" 2>/dev/null)
python3 -c "import sys;sys.exit(0 if float('${SP:-0}')>0 else 1)" 2>/dev/null \
  && ok "user1 spend attributed (\$$SP)" || no "user1 spend not tracked (\$${SP:-?}) — expected for Codex-only if unpriced"

# ---- Cap enforcement ----
echo "== cap enforcement =="
curl -s "$GW/key/update" "${auth[@]}" -d "{\"key\":\"$K1\",\"max_budget\":0.0000001}" >/dev/null
sleep 45   # spend buffer is eventually-consistent; give it time to propagate
DENIED=0
for _ in 1 2 3; do
  R=$(callm "$K1" "$CLAUDE_MODEL" "hi")
  echo "$R" | grep -qi "budget has been exceeded" && { DENIED=1; break; }
  sleep 8
done
[ "$DENIED" = 1 ] && ok "over-budget key denied" || no "over-budget key not denied (buffer may need longer)"

# ---- Optional cleanup ----
if [ "$CLEANUP" = 1 ]; then
  echo "== cleanup =="
  curl -s "$GW/key/delete" "${auth[@]}" -d "{\"keys\":[\"$K1\",\"$K2\"]}" >/dev/null
  curl -s "$GW/team/delete" "${auth[@]}" -d "{\"team_ids\":[\"$TID\"]}" >/dev/null
  echo "  removed test team + keys"
fi

echo ""
echo "== RESULT: $pass passed, $fail failed =="
[ "$fail" = 0 ]
