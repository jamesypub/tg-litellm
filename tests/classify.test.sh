#!/usr/bin/env bash
# Table-driven unit test for the #32 denial classifier (tests/lib-classify.sh).
# Runs OFFLINE (no network/AWS/container) so broad-token / wrong-class / transport
# regressions fail BEFORE publish — not only via QA's live adversarial repro.
#   ./tests/classify.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib-classify.sh
. tests/lib-classify.sh

pass=0; fail=0
# expect $1=PASS|FAIL for classify_denial with given (blob,is_err,exit,want,label)
check() {
  local want_result="$1" blob="$2" is_err="$3" ex="$4" want_re="$5" label="$6" got
  got="$(classify_denial "$blob" "$is_err" "$ex" "$want_re")"; got="${got%% *}"
  if [ "$got" = "$want_result" ]; then echo "  PASS $label ($got)"; pass=$((pass+1))
  else echo "  FAIL $label: got $got, want $want_result"; fail=$((fail+1)); fi
}

# --- real governance denials must PASS their own class ---
check PASS '{"is_error":true,"result":"401 authentication_error: invalid x-api-key"}' 1 1 "$CLASS_INVALID_KEY" "real invalid-key 401"
# REAL LiteLLM wording (QA #32): "proxy" here = gateway token, NOT a network proxy.
# These MUST pass invalid/revoked auth and must NOT be swallowed as transport.
check PASS '{"is_error":true,"result":"Authentication Error, Invalid proxy server token passed."}' 1 1 "$CLASS_INVALID_KEY" "LiteLLM invalid-proxy-token -> invalid auth"
check PASS '{"is_error":true,"result":"Authentication Error, Invalid proxy server token passed."}' 1 1 "$CLASS_REVOKED_KEY" "LiteLLM invalid-proxy-token -> revoked auth"
check PASS '{"is_error":true,"result":"Budget has been exceeded!"}'                    1 1 "$CLASS_OVER_BUDGET"  "real budget-exceeded"
check PASS '{"is_error":true,"result":"key not allowed to access model foo (403)"}'   1 1 "$CLASS_DISALLOWED_MODEL" "real model-access 403"
check PASS '{"is_error":true,"result":"authentication_error: key not found"}'         1 1 "$CLASS_REVOKED_KEY" "real revoked key-not-found"

# --- QA's wrong-class / broad-token counterexamples must FAIL ---
check FAIL '{"is_error":true,"result":"Corporate proxy request quota exceeded (403)"}' 1 1 "$CLASS_OVER_BUDGET" "proxy-quota 403 must NOT be budget (bare exceeded)"
check FAIL '{"is_error":true,"result":"Configuration file not found"}'                 1 1 "$CLASS_REVOKED_KEY" "config-not-found must NOT be revoked (bare not-found)"
check FAIL '{"is_error":true,"result":"some unrelated 403 forbidden"}'                 1 1 "$CLASS_DISALLOWED_MODEL" "unrelated 403 must NOT be model-denial (bare 403)"

# --- transport / connectivity errors must FAIL even with is_error + status word ---
check FAIL '{"is_error":true,"result":"connection refused to gateway"}'               1 1 "$CLASS_INVALID_KEY" "connection refused = transport"
check FAIL '{"is_error":true,"result":"getaddrinfo ENOTFOUND gw.example"}'            1 1 "$CLASS_INVALID_KEY" "DNS ENOTFOUND = transport"
check FAIL '{"is_error":true,"result":"TLS certificate verify failed"}'               1 1 "$CLASS_INVALID_KEY" "TLS error = transport"
check FAIL '{"is_error":true,"result":"proxy connect ECONNREFUSED 10.0.0.1:8080"}'    1 1 "$CLASS_INVALID_KEY" "real network-proxy connect failure = transport (compound)"
check FAIL '{"is_error":true,"result":"407 Proxy Authentication Required"}'           1 1 "$CLASS_INVALID_KEY" "407 proxy-auth = transport"

# --- structural guards ---
check FAIL '{"result":"CLAUDE_E2E_OK"}'                                                1 1 "$CLASS_INVALID_KEY" "success text present"
check FAIL '{"is_error":true,"result":"invalid x-api-key"}'                            1 124 "$CLASS_INVALID_KEY" "timeout 124 inconclusive"
check FAIL 'plain non-json invalid api key'                                            0 1 "$CLASS_INVALID_KEY" "no completed structured error (is_err=0)"

echo ""
echo "== classify: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
