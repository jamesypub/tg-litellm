#!/usr/bin/env bash
# Pure, testable denial classifier for the Claude Code CLI negatives (#32).
# Separated from e2e.sh so its decision table can be unit-tested offline
# (tests/classify.test.sh) — broad-token regressions must fail BEFORE publish,
# not only via QA's live adversarial repro.
#
# classify_denial <blob> <is_err:0|1> <exit> <expected_class_regex>
#   echoes: "PASS <matched>"  or  "FAIL <reason>"
#
# A real governance denial must be ALL of: no success text; a COMPLETED structured
# error (exit != 124 and is_err=1 — is_err alone is NOT enough); NOT a transport /
# DNS / TLS / connectivity error; AND a match for the case-specific expected class.
# Expected-class regexes must be denial-specific (no bare 403/exceeded/not-found).

# Network transport/connectivity failures — NOT governance denials. NOTE: do NOT
# put a bare `proxy` here: LiteLLM's real AUTH denial says "Invalid proxy server
# token" (proxy = the LiteLLM gateway token, not a network proxy). Match a network
# proxy failure only with compound context (proxy + connect/timeout/unreachable) or
# an explicit 407 proxy-auth status. (#32)
# shellcheck disable=SC2016
_TRANSPORT_RE='connection refused|could not connect|econnrefused|enotfound|getaddrinfo|dns|timed? out|etimedout|network|tls|ssl|certificate|socket|econnreset|fetch failed|unable to reach|connection error|proxy (connect|error|unreachable|timeout|refused)|407'

# Per-case EXPECTED denial-class regexes (single source of truth for e2e.sh + tests).
# Denial-specific only — NO bare 403/exceeded/not-found (those matched unrelated
# structured errors: a proxy-quota 403, a config-not-found, etc. — QA #32).
# shellcheck disable=SC2034
CLASS_INVALID_KEY='invalid.?api.?key|invalid.?x-api-key|invalid proxy server token|authentication_error|authentication error|no auth credentials|unauthorized'
# shellcheck disable=SC2034
CLASS_DISALLOWED_MODEL='not allowed to access model|model_access_denied|key not allowed to access'
# shellcheck disable=SC2034
CLASS_OVER_BUDGET='budget has been exceeded|budget_exceeded|exceeded.{0,20}budget|max_budget|over budget'
# shellcheck disable=SC2034
CLASS_REVOKED_KEY='invalid.?api.?key|invalid.?x-api-key|invalid proxy server token|authentication_error|key not found|no such key|key.{0,20}(revoked|deleted|expired)|unauthorized'

classify_denial() {
  local blob="$1" is_err="$2" ex="$3" want="$4"
  if printf '%s' "$blob" | grep -q 'CLAUDE_E2E_OK'; then
    echo "FAIL success-text"; return 1
  fi
  if [ "${ex:-1}" = "124" ]; then
    echo "FAIL timeout-124-inconclusive"; return 1
  fi
  if [ "$is_err" != "1" ]; then
    echo "FAIL no-completed-structured-error"; return 1
  fi
  # transport/connectivity/proxy errors are NOT governance denials.
  if printf '%s' "$blob" | grep -qiE "$_TRANSPORT_RE"; then
    echo "FAIL transport-not-governance"; return 1
  fi
  if printf '%s' "$blob" | grep -qiE "$want"; then
    echo "PASS matched-expected-class"; return 0
  fi
  echo "FAIL wrong-class"; return 1
}
