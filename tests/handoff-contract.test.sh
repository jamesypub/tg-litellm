#!/usr/bin/env bash
# Contract test for the admin→developer handoff renderer (#41 R3). Runs OFFLINE by
# stubbing aws/curl/codex, renders both packages, EXECUTES them in a throwaway
# HOME, and asserts the package is self-contained + fully expanded — the class of
# live-only bug (#43/#44/#48/#50) that source-string checks miss.
#
#   ./tests/handoff-contract.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd)"
pass=0; fail=0
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"

# --- stubs on PATH: aws / curl / codex / make-codex-catalog behave predictably ---
cat > "$BIN/aws" <<'STUB'
#!/usr/bin/env bash
# only used for: secretsmanager get-secret-value ... SecretString
echo "sk-master-stub-value"
STUB
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
# Emulate the gateway. --config <file> carries auth (we ignore it). We answer:
#   /key/generate -> a key + models ; /key/info -> models
args="$*"
case "$args" in
  # /v1/models: the SERVING registry the renderer validates against (#45). Includes
  # bare client-compatible aliases AND the slash/scope names (served, CLI-rejected).
  */v1/models*)    echo '{"data":[{"id":"claude-opus-4-8"},{"id":"global/claude-opus-4-8"},{"id":"us/claude-opus-4-8"},{"id":"openai.gpt-5.6-sol"},{"id":"openai.gpt-5.4"}]}' ;;
  */user/new*)     echo '{"user_id":"dev-alice"}' ;;
  # /team/info: team 'team-real' exists; anything else is an error (#55 validation).
  */team/info*team_id=team-real*) echo '{"team_info":{"team_id":"team-real"}}' ;;
  */team/info*)    echo '{"error":{"message":"team not found"}}' ;;
  # /key/generate now echoes the owning user_id (#55 ownership must attach).
  */key/generate*) echo '{"key":"sk-dev-stub-KEY","user_id":"dev-alice","models":["claude-opus-4-8","openai.gpt-5.6-sol","openai.gpt-5.4"]}' ;;
  */key/info*)     echo '{"info":{"models":["claude-opus-4-8","openai.gpt-5.6-sol","openai.gpt-5.4"]}}' ;;
  *)               echo '{}' ;;
esac
STUB
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  debug) echo '{"models":[{"slug":"gpt-5.6-sol"}]}' ;;
  --version) echo "codex 0.144.6" ;;
  *) : ;;
esac
STUB
# make-codex-catalog stub: emit one {"models":[{...}]} per call (per requested model)
cat > "$BIN/make-codex-catalog.sh" <<'STUB'
#!/usr/bin/env bash
printf '{"models":[{"slug":"%s","use_responses_lite":false}]}\n' "$1"
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

# Fake installer handoff so the renderer has its non-secret facts.
cat > "$REPO/deploy/handoff.contracttest.json" <<'JSON'
{
  "schema": "tg-llmgateway/handoff@1",
  "environment": "contracttest",
  "gateway_url": "https://gw.example.test",
  "admin_url": "https://gw.example.test/ui",
  "client_facing_model_aliases": ["claude-opus-4-8","openai.gpt-5.6-sol","openai.gpt-5.4"],
  "enabled_clients": ["claude","codex"],
  "supported_client_versions": {"claude_code":"2.1.214","codex":"0.144.6"},
  "secret_references": {"master_key_secret_arn":"arn:aws:secretsmanager:us-east-1:000000000000:secret:stub"}
}
JSON
trap 'rm -rf "$WORK"; rm -f "$REPO/deploy/handoff.contracttest.json"' EXIT
export AWS_PROFILE=stub

# assert an executable (non-comment) line has no unexpanded $UPPER var or <angle>
assert_expanded() { # $1 file  $2 label
  local bad
  bad="$(grep -vE '^\s*#' "$1" | grep -nE '\$[A-Z_]{2,}|\$\{[A-Z_]+\}|<[A-Za-z_]+>' | grep -vE 'HOME|PWD|PATH|LG_ENV|CLAUDE_CONFIG_DIR|\$\{!' || true)"
  [ -z "$bad" ] && ok "$2 fully expanded (no leftover placeholders)" || { no "$2 has unexpanded tokens"; echo "$bad" | sed 's/^/       /'; }
}

echo "== render + execute CLAUDE package in a throwaway HOME =="
CL_PKG="$WORK/claude.pkg.sh"
if AWS_PROFILE=stub ./deploy/render-handoff.sh contracttest claude dev-alice \
     --create 50 'claude-opus-4-8' > "$CL_PKG" 2>"$WORK/cl.err"; then
  ok "claude render exited 0"
  assert_expanded "$CL_PKG" "claude package"
  # execute in a throwaway HOME
  H="$WORK/home-claude"; mkdir -p "$H"
  HOME="$H" bash "$CL_PKG" >/dev/null 2>&1 || true
  [ -f "$H/.claude-lg-contracttest/settings.json" ] && ok "claude settings.json created" || no "claude settings.json missing"
  # the key must be baked (not a literal $VIRTUAL_KEY), and be the stub value
  grep -q 'sk-dev-stub-KEY' "$H/.claude-lg-contracttest/settings.json" 2>/dev/null && ok "claude key baked into settings" || no "claude key not baked"
  # launcher present + scrubs provider env
  grep -q 'env -u CLAUDE_CODE_USE_BEDROCK' "$H/.bash_profile" 2>/dev/null && ok "claude launcher scrubs provider env (#47)" || no "claude launcher missing scrub"
  # #39: executing the package in a CLEAN home (no managed-settings file) must NOT
  # print a false "managed settings present" — and must not call a missing ./deploy script.
  cl_out="$(HOME="$WORK/home-claude-clean" bash "$CL_PKG" 2>&1)"; :
  printf '%s' "$cl_out" | grep -qi 'managed .*settings present' && no "#39 package false-positives managed settings in a clean home" || ok "#39 no managed-settings false-positive in a clean home"
  printf '%s' "$cl_out" | grep -q 'deploy/check-claude-managed-settings.sh' && no "#39 package calls a missing relative ./deploy script" || ok "#39 package inlines the managed check (no relative-script call)"
else
  no "claude render failed"; sed 's/^/       /' "$WORK/cl.err"
fi

echo "== render + execute CODEX package in a throwaway HOME =="
CX_PKG="$WORK/codex.pkg.sh"
if AWS_PROFILE=stub ./deploy/render-handoff.sh contracttest codex dev-alice \
     --create 50 'openai.gpt-5.6-sol,openai.gpt-5.4' > "$CX_PKG" 2>"$WORK/cx.err"; then
  ok "codex render exited 0"
  assert_expanded "$CX_PKG" "codex package"
  H="$WORK/home-codex"; mkdir -p "$H"
  HOME="$H" bash "$CX_PKG" >/dev/null 2>&1 || true
  # every referenced file must exist (the #44 dangling-catalog class)
  [ -f "$H/.codex/contracttest.config.toml" ] && ok "codex profile toml created" || no "codex profile toml missing"
  [ -f "$H/.codex/contracttest-models.json" ] && ok "codex catalog file created (referenced file exists, #44)" || no "codex catalog file MISSING (dangling reference)"
  [ -f "$H/.codex/contracttest.key" ] && ok "codex key file created" || no "codex key file missing"
  # catalog covers BOTH allowlisted codex models (#44)
  n="$(python3 -c "import json;print(len(json.load(open('$H/.codex/contracttest-models.json')).get('models',[])))" 2>/dev/null || echo 0)"
  [ "${n:-0}" -ge 2 ] && ok "codex catalog covers all allowlisted models ($n)" || no "codex catalog incomplete ($n/2)"
  # config path points inside the pasted HOME, not the admin host
  grep -q "$H/.codex/contracttest-models.json" "$H/.codex/contracttest.config.toml" 2>/dev/null && ok "catalog path resolves in the developer HOME (#44)" || no "catalog path wrong (admin-host leak)"
else
  no "codex render failed"; sed 's/^/       /' "$WORK/cx.err"
fi

echo "== #45: --create fails closed when a requested model is NOT served =="
# A bare alias the gateway does not serve must be rejected BEFORE a key is minted,
# with the served client-compatible aliases listed.
if AWS_PROFILE=stub ./deploy/render-handoff.sh contracttest claude dev-bob \
     --create 50 'claude-not-served-9' >/dev/null 2>"$WORK/ns.err"; then
  no "#45 render should fail for an unserved model"
else
  grep -q 'not served by the gateway' "$WORK/ns.err" && ok "#45 unserved model rejected before key creation" || { no "#45 wrong error for unserved model"; sed 's/^/       /' "$WORK/ns.err"; }
fi

echo "== #45: slash/scope-only Claude allowlist is rejected as CLI-incompatible =="
# Use --key-file mode so --models is the authoritative allowlist (in --create mode
# the stub gateway always echoes its fixed allowlist regardless of the request).
# A key allowing ONLY global/… must fail closed — Claude Code rejects slash aliases.
if printf 'sk-dev-stub-KEY' | AWS_PROFILE=stub ./deploy/render-handoff.sh contracttest claude dev-bob \
     --key-file - --models 'global/claude-opus-4-8' >/dev/null 2>"$WORK/slash.err"; then
  no "#45 render should fail for a slash/scope-only Claude allowlist"
else
  grep -q '#45' "$WORK/slash.err" && ok "#45 slash/scope-only Claude allowlist fails closed (CLI-incompatible)" || { no "#45 wrong error for slash-only allowlist"; sed 's/^/       /' "$WORK/slash.err"; }
fi

echo "== #55: created key carries user ownership (spend attribution) =="
# The claude package rendered above used --create without --user; ownership must be
# derived (never null). Render with an explicit --user and assert the ownership note.
if AWS_PROFILE=stub ./deploy/render-handoff.sh contracttest claude dev-alice \
     --create 50 'claude-opus-4-8' --user alice >/dev/null 2>"$WORK/own.err"; then
  grep -q "owned by user" "$WORK/own.err" && ok "#55 renderer confirms key ownership (user attached)" || { no "#55 no ownership confirmation"; sed 's/^/       /' "$WORK/own.err"; }
else
  no "#55 render with --user failed"; sed 's/^/       /' "$WORK/own.err"
fi

echo "== #55: --team validates the team exists (fail closed on nonexistent) =="
# A nonexistent team must be rejected BEFORE a key is minted — not attached and rendered.
if AWS_PROFILE=stub ./deploy/render-handoff.sh contracttest claude dev-alice \
     --create 50 'claude-opus-4-8' --user alice --team team-ghost >/dev/null 2>"$WORK/team.err"; then
  no "#55 render should fail closed for a nonexistent team"
else
  grep -q "does not exist" "$WORK/team.err" && ok "#55 nonexistent team rejected before key creation" || { no "#55 wrong error for nonexistent team"; sed 's/^/       /' "$WORK/team.err"; }
fi

echo "== #55: --team attaches when the team exists =="
if AWS_PROFILE=stub ./deploy/render-handoff.sh contracttest claude dev-alice \
     --create 50 'claude-opus-4-8' --user alice --team team-real >/dev/null 2>"$WORK/teamok.err"; then
  grep -q "team 'team-real' validated" "$WORK/teamok.err" && ok "#55 existing team validated + attached" || { no "#55 existing team not confirmed"; sed 's/^/       /' "$WORK/teamok.err"; }
else
  no "#55 render with a real team failed"; sed 's/^/       /' "$WORK/teamok.err"
fi

echo "== #43: render with NO key source fails closed =="
AWS_PROFILE=stub ./deploy/render-handoff.sh contracttest claude dev-alice >/dev/null 2>&1 \
  && no "render should fail with no key source" || ok "render fails closed without --create/--key-file (#43)"

echo "== #50: tg_curl removes its auth --config even on FORCED curl failure (under set -e) =="
# Isolated TMPDIR so cleanup is checked precisely (no /tmp-wide scan). curl to a
# closed localhost port -> connection refused (exit 7); the config must still be gone.
T50="$WORK/t50"; mkdir -p "$T50"
( set -e
  export TMPDIR="$T50"
  # shellcheck source=deploy/lib.sh
  . "$REPO/deploy/lib.sh"
  TMPDIR="$T50" tg_curl "Authorization: Bearer" "CFGMARKER-should-not-leak" -s -m 2 --connect-timeout 2 "http://127.0.0.1:1/nope" || true
) >/dev/null 2>&1 || true
leak="$(grep -rl 'CFGMARKER-should-not-leak' "$T50" 2>/dev/null | head -1 || true)"
[ -z "$leak" ] && ok "no auth --config left after forced curl failure (#50)" || { no "auth --config leaked after forced curl failure (#50)"; }

echo ""
echo "== handoff-contract: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
