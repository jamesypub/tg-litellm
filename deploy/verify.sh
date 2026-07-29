#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&B||C idiom is intentional; reporters never fail
# Post-install API smoke — proves the gateway itself works end to end.
#
#   AWS_PROFILE=<profile> ./verify.sh <env>
#
# Checks: gateway health, model listing, one real Claude request via the Anthropic
# MESSAGES route, and — when Codex is enabled — one Codex request via the OpenAI
# RESPONSES route. Route selection matches the published client config (#40.3):
# Claude=/v1/messages, Codex=/v1/responses (NOT /v1/chat/completions).
#
# Codex verify policy (#72): with Codex on by default (#61), a Codex CREDENTIAL/
# MODEL/REGION that isn't ready (no model registered, or HTTP 400/401/403/404 from
# the Responses route) is a LOUD WARNING — Claude still passes and the install
# succeeds. Only a route that is configured + reachable but ERRORING (HTTP 5xx, or
# 200 with a malformed body) fails verification closed. When enable_codex is not
# true, Codex is skipped cleanly and Claude-only still passes. (#40.3/#40.4/#72)
#
# SCOPE (#32): this is an OPERATOR-level API smoke using the master key. It does
# NOT qualify the developer workflow — it does not exercise Claude Code / Codex
# CLIs, per-user virtual keys, budget/allowlist enforcement, or the published
# client setup. For that, run tests/e2e.sh (real Claude Code + Codex CLIs in the
# dev container with a per-user key) and follow docs/client-setup.md.
cd "$(dirname "$0")" || exit 1
. ./lib.sh
tg_init "${1:-}"

# With CloudFront enabled the ALB 403s direct traffic, so verify the public
# CloudFront endpoint (matches deploy.sh install / tests/e2e.sh). Fall back to
# the ALB URL when CloudFront is off.
if [ "$(tf_output cloudfront_enabled 2>/dev/null || echo false)" = "true" ]; then
  GW="$(tf_output cloudfront_url)"
else
  GW="$(tf_output alb_url)"
fi
MK_ARN="$(tf_output master_key_secret_arn)"
MK="$(aws secretsmanager get-secret-value --secret-id "$MK_ARN" --query SecretString --output text)"
[ -n "$MK" ] || { echo "ERROR: could not read master key from $MK_ARN"; exit 1; }
echo "==> gateway: $GW"

fail=0
echo "== health =="
if curl -sf -m 15 "$GW/health/liveliness" >/dev/null 2>&1; then echo "  ok   healthy"; else echo "  ERR  unreachable (check ingress allowlist / that you're on an allowed IP)"; fail=1; fi

echo "== models =="
MODELS="$(tg_curl "Authorization: Bearer" "$MK" -s -m 20 "$GW/v1/models" | python3 -c "import sys,json;[print(m['id']) for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null)"
COUNT="$(printf '%s\n' "$MODELS" | grep -c . || true)"
[ "${COUNT:-0}" -gt 0 ] && echo "  ok   $COUNT models registered" || { echo "  ERR  no models (run ./register-models.sh)"; fail=1; }

CLAUDE="$(printf '%s\n' "$MODELS" | grep -m1 -E 'claude' || true)"
CODEX="$(printf '%s\n' "$MODELS" | grep -m1 -E 'gpt-5' || true)"

# Is Codex enabled for this env? Explicit tfvars flag (#40.4). When true, the
# Codex Responses route is a REQUIRED, fail-closed check.
CODEX_ENABLED=0
[ "$(tfvars_get "$TFVARS" enable_codex)" = "true" ] && CODEX_ENABLED=1

echo "== Claude request (Anthropic Messages route) =="
if [ -n "$CLAUDE" ]; then
  # Anthropic-native Messages route: /v1/messages, x-api-key + anthropic-version,
  # and a top-level max_tokens. A 'content' array in the response = success.
  R="$(tg_curl "x-api-key:" "$MK" -s -m 40 "$GW/v1/messages" -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
        -d "{\"model\":\"$CLAUDE\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Say hi in 3 words.\"}]}")"
  if printf '%s' "$R" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if isinstance(d.get('content'),list) and d.get('content') else 1)" 2>/dev/null; then
    echo "  ok   $CLAUDE responded via /v1/messages"
  else echo "  ERR  Claude Messages call failed: $(printf '%s' "$R" | head -c 140)"; fail=1; fi
else echo "  ERR  no Claude model registered"; fail=1; fi

echo "== Codex request (OpenAI Responses route) =="
# (#72) Codex verify policy: with Codex ON BY DEFAULT (#61), do NOT fail a good
# Claude install just because the Codex CREDENTIAL/MODEL/REGION isn't ready yet.
# - "not ready" (no Codex model registered; or the route returns 400/401/403/404
#   = key not minted / not authorized / model not enabled in this region) -> LOUD
#   WARNING, install still PASSES (Claude works).
# - "configured + reachable but erroring" (HTTP 5xx, or 200 with a malformed body)
#   -> FAIL closed: the route is wired but broken, which is a real defect.
codex_warn=0
if [ "$CODEX_ENABLED" = 1 ]; then
  if [ -n "$CODEX" ]; then
    # Capture body + HTTP status (status on the last line via -w).
    R="$(tg_curl "Authorization: Bearer" "$MK" -s -m 40 -w '\n%{http_code}' "$GW/v1/responses" -H "Content-Type: application/json" \
          -d "{\"model\":\"$CODEX\",\"input\":\"Say hi in 3 words.\"}")"
    CODE="$(printf '%s' "$R" | tail -n1)"
    BODY="$(printf '%s' "$R" | sed '$d')"
    if printf '%s' "$BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if (d.get('output') or d.get('output_text')) else 1)" 2>/dev/null; then
      echo "  ok   $CODEX responded via /v1/responses"
    else
      case "$CODE" in
        400|401|403|404)
          echo "  warn Codex not ready (HTTP $CODE) — key not minted / not authorized / model not enabled in this region. Claude is unaffected; enable Mantle access or set enable_codex=false. Detail: $(printf '%s' "$BODY" | head -c 140)"
          codex_warn=1 ;;
        *)
          echo "  ERR  Codex route configured + reachable but erroring (HTTP $CODE): $(printf '%s' "$BODY" | head -c 140)"; fail=1 ;;
      esac
    fi
  else
    # No Codex model registered = credential/model not ready, not a broken gateway.
    echo "  warn enable_codex=true but no Codex model is registered — Codex credential/model not ready. Claude is unaffected; see register-models / Mantle region access. (enable_codex=false for a Claude-only install.)"
    codex_warn=1
  fi
else
  echo "  skip Codex not enabled (enable_codex != true) — Claude-only install"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  if [ "$codex_warn" = 1 ]; then
    echo "== verify: PASS (Claude OK; Codex NOT READY — see warning above) =="
  else
    echo "== verify: PASS =="
  fi
  echo "Hand off: URL $GW/ui  (user admin / your ui_password), master key in $MK_ARN"
else
  echo "== verify: FAIL =="; exit 1
fi
