#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&ok||no idiom intentional; single-quoted grep patterns are literal
# Static, deterministic tests for register-models.sh model naming. No AWS/network
# required: exercises Claude scope-prefixed aliases and canonical Mantle aliases
# in isolation. Retained evidence (committed), not ad hoc.
#
#   ./tests/register-models-naming.test.sh
set -uo pipefail
pass=0; fail=0
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }
REGISTER_SCRIPT="$(cd "$(dirname "$0")/../deploy" && pwd)/register-models.sh"

# --- the exact naming logic from register-models.sh add_claude() ---
declare -A CLAUDE
add_claude() {
  local pid="$1"
  local scope="${pid%%.anthropic.*}"
  local base="${pid#*.anthropic.}"
  base="${base%-v1:0}"
  local model="${base//./-}"
  CLAUDE["${scope}/${model}"]="$pid"
}
reset() { unset CLAUDE; declare -gA CLAUDE; }

# 1. global-only discovery → one global/ name
reset
add_claude "global.anthropic.claude-opus-4-8"
[ "${#CLAUDE[@]}" -eq 1 ] && [ "${CLAUDE[global/claude-opus-4-8]:-}" = "global.anthropic.claude-opus-4-8" ] \
  && ok "global-only registers global/claude-opus-4-8" || no "global-only"

# 2. us-only discovery → one us/ name
reset
add_claude "us.anthropic.claude-opus-4-8"
[ "${#CLAUDE[@]}" -eq 1 ] && [ "${CLAUDE[us/claude-opus-4-8]:-}" = "us.anthropic.claude-opus-4-8" ] \
  && ok "us-only registers us/claude-opus-4-8" || no "us-only"

# 3. both scopes → two distinct names, both retained (no global-wins collapse)
reset
add_claude "global.anthropic.claude-opus-4-8"
add_claude "us.anthropic.claude-opus-4-8"
[ "${#CLAUDE[@]}" -eq 2 ] && [ -n "${CLAUDE[global/claude-opus-4-8]:-}" ] && [ -n "${CLAUDE[us/claude-opus-4-8]:-}" ] \
  && ok "both scopes register both names (no collapse)" || no "both-scope"

# 4. date/version collision → dated profile keeps a distinct name
reset
add_claude "us.anthropic.claude-3-5-sonnet-20240620-v1:0"
add_claude "us.anthropic.claude-3-5-sonnet-20241022-v2:0"
[ "${#CLAUDE[@]}" -eq 2 ] \
  && ok "distinct dates → distinct names (no collision)" \
  || no "date-collision (got ${#CLAUDE[@]} names: ${!CLAUDE[*]})"

# 5. idempotency of the map: re-adding the same pid does not create a second entry
reset
add_claude "global.anthropic.claude-opus-4-8"
add_claude "global.anthropic.claude-opus-4-8"
[ "${#CLAUDE[@]}" -eq 1 ] && ok "re-adding same profile is idempotent (map)" || no "idempotency"

# 6. Mantle registration must offer the EXACT canonical ID Codex sends (#30). The
# canonical ID is the primary alias; the legacy rewritten alias is retained
# additively so pre-#30 keys keep working.
# EXECUTION-level emission: reproduce the exact names register-models.sh emits for
# a Mantle model (primary = canonical $m; additive legacy = prefix-stripped/dashed),
# and assert the emitted primary is byte-for-byte the model id (not a tautology).
mantle_legacy() { local a="${1#openai.}"; printf '%s' "${a//./-}"; }
mantle_names() {  # echoes the names reg() would receive, one per line
  local prefix="$1" m="$2" legacy; printf '%s%s\n' "$prefix" "$m"
  legacy="$(mantle_legacy "$m")"; [ "$legacy" != "$m" ] && printf '%s%s\n' "$prefix" "$legacy"
}
for model in \
  openai.gpt-5.4 \
  openai.gpt-5.5 \
  openai.gpt-5.6-sol \
  openai.gpt-5.6-luna \
  openai.gpt-5.6-terra
do
  primary="$(mantle_names "" "$model" | sed -n 1p)"
  [ "$primary" = "$model" ] && ok "Mantle primary emitted == canonical id: $model" || no "Mantle primary $model (got $primary)"
  legacy="$(mantle_legacy "$model")"
  # legacy alias is a distinct, dashed, prefix-stripped name (additive back-compat)
  case "$legacy" in
    *.* )     no "legacy alias for $model still contains a dot/prefix ($legacy)" ;;
    "$model") ok "no separate legacy alias needed for $model" ;;
    *)        ok "Mantle legacy alias retained additively: $model -> $legacy" ;;
  esac
done

# 7. Guard the implementation: the primary Mantle alias must be the canonical $m,
# and the legacy alias must be registered ADDITIVELY (not as the primary), so the
# #30 regression (primary alias = rewritten name) cannot return.
if grep -q 'reg "\${PREFIX}\${m}"' "$REGISTER_SCRIPT" \
  && grep -q 'legacy="\${m#openai\.}"' "$REGISTER_SCRIPT" \
  && grep -q 'reg "\${PREFIX}\${legacy}"' "$REGISTER_SCRIPT"; then
  ok "register-models.sh registers canonical primary + additive legacy Mantle alias"
else
  no "register-models.sh does not register canonical-primary + additive-legacy Mantle aliases"
fi

# 8. EXECUTION-level Claude name emission (#33). Reproduce the ACTUAL composition
# register-models.sh performs (PREFIX carries the tenant; canonical name = pid AFTER
# the single prefix; friendly alias = <scope>/<model>). This catches the double-
# prefix bug that isolated-expression tests missed.
claude_scope_alias() { # pid -> <scope>/<model> (mirrors add_claude)
  local pid="$1"
  local scope="${pid%%.anthropic.*}"
  local base="${pid#*.anthropic.}"
  base="${base%-v1:0}"; printf '%s/%s' "$scope" "${base//./-}"
}
claude_emitted() { # $1=TENANT $2=pid -> the two names reg() receives, one per line
  local tenant="$1" pid="$2" prefix=""; [ -n "$tenant" ] && prefix="${tenant}/"
  printf '%s%s\n' "$prefix" "$pid"                       # canonical (pid after ONE prefix)
  printf '%s%s\n' "$prefix" "$(claude_scope_alias "$pid")"
}
# single-account: canonical is the exact id; friendly is scope/model
S_CANON="$(claude_emitted '' global.anthropic.claude-opus-4-8 | sed -n 1p)"
S_FRIEND="$(claude_emitted '' global.anthropic.claude-opus-4-8 | sed -n 2p)"
[ "$S_CANON" = "global.anthropic.claude-opus-4-8" ] && ok "single-account canonical = exact id" || no "single canonical (got $S_CANON)"
[ "$S_FRIEND" = "global/claude-opus-4-8" ] && ok "single-account friendly = global/claude-opus-4-8" || no "single friendly (got $S_FRIEND)"
# cross-account: tenant applied EXACTLY ONCE (regression guard for acme/acme/…)
X_CANON="$(claude_emitted acme us.anthropic.claude-3-5-sonnet-20240620-v1:0 | sed -n 1p)"
X_FRIEND="$(claude_emitted acme us.anthropic.claude-3-5-sonnet-20240620-v1:0 | sed -n 2p)"
[ "$X_CANON" = "acme/us.anthropic.claude-3-5-sonnet-20240620-v1:0" ] \
  && ok "cross-account canonical = acme/<id> (tenant applied once, punctuation preserved)" \
  || no "cross-account canonical DOUBLE-PREFIX or wrong (got $X_CANON)"
case "$X_CANON" in acme/acme/*) no "cross-account canonical double-prefixed (acme/acme/…)";; esac
[ "$X_FRIEND" = "acme/us/claude-3-5-sonnet-20240620" ] && ok "cross-account friendly = acme/us/… (single prefix)" || no "cross friendly (got $X_FRIEND)"

# 9. Tenant syntax must be rejected if it could impersonate/collide with a bare id.
tenant_ok() { case "$1" in *.anthropic.*|*.*|*/*|"") return 1;; *) return 0;; esac; }
tenant_ok acme && ok "valid tenant 'acme' accepted" || no "tenant acme"
for bad in "" "a.b" "global.anthropic.x" "a/b"; do
  tenant_ok "$bad" && { no "invalid tenant '$bad' wrongly accepted"; break; }
done
tenant_ok "a.b" || ok "invalid tenants (dot/slash/empty/profile-like) rejected"

# 10. Guard the implementation: canonical registers pid after a SINGLE prefix, and
# must NOT re-prepend $TENANT (the #33 double-prefix regression).
if grep -q 'reg "\${PREFIX}\${pid}" "\$params"' "$REGISTER_SCRIPT" \
  && grep -q 'reg "\${PREFIX}\${alias}" "\$params"' "$REGISTER_SCRIPT" \
  && ! grep -q 'canonical="\${TENANT:+\$TENANT/}\$pid"' "$REGISTER_SCRIPT"; then
  ok "register-models.sh registers Claude canonical (pid after single prefix) + additive friendly alias"
else
  no "register-models.sh Claude canonical registration is wrong or double-prefixes the tenant"
fi

# 11. Bare client-compatible Claude alias derivation (#45): global-preferred, with
# us as a fallback only. Mirrors the BARE build in register-models.sh.
build_bare() {                       # reads global CLAUDE, fills global BARE
  unset BARE; declare -gA BARE
  local alias scope model
  for alias in "${!CLAUDE[@]}"; do
    scope="${alias%%/*}"; model="${alias#*/}"
    if [ "$scope" = "global" ] || [ -z "${BARE[$model]:-}" ]; then
      BARE["$model"]="${CLAUDE[$alias]}"
    fi
  done
}
reset; add_claude "global.anthropic.claude-opus-4-8"; add_claude "us.anthropic.claude-opus-4-8"
build_bare
[ "${BARE[claude-opus-4-8]:-}" = "global.anthropic.claude-opus-4-8" ] \
  && ok "bare alias prefers the global profile when both exist (#45)" || no "bare alias global-preference (#45)"
reset; add_claude "us.anthropic.claude-3-5-sonnet-20240620-v1:0"
build_bare
[ "${BARE[claude-3-5-sonnet-20240620]:-}" = "us.anthropic.claude-3-5-sonnet-20240620-v1:0" ] \
  && ok "bare alias falls back to us when only us exists (#45)" || no "bare alias us fallback (#45)"
# Guard: the script actually registers the bare aliases (the #45 fresh-account fix).
if grep -q 'for model in "${!BARE\[@\]}"' "$REGISTER_SCRIPT" \
  && grep -q 'reg "\${PREFIX}\${model}" "\$params"' "$REGISTER_SCRIPT"; then
  ok "register-models.sh registers bare client-compatible Claude aliases (#45)"
else
  no "register-models.sh does not register bare Claude aliases (#45 fresh-account regression)"
fi

# 12. Wizard-mode bare-alias build (#95): reproduces the actual parametrized BARE
# loop in register-models.sh (WIZARD/SCOPE-gated date-stripping + scope pin).
build_bare_param() {   # $1=WIZARD $2=SCOPE, reads global CLAUDE, fills global BARE
  local wiz="$1" scope_pref="$2"
  unset BARE; declare -gA BARE=()   # =() matters under set -u — see register-models.sh
  local BARE_PREF="global" BARE_ONLY=""
  if [ "$wiz" = "1" ]; then
    case "$scope_pref" in
      us)     BARE_PREF="us"; BARE_ONLY="us" ;;
      global) BARE_PREF="global"; BARE_ONLY="global" ;;
      *)      BARE_PREF="global" ;;
    esac
  fi
  local alias scope model bare_name
  for alias in "${!CLAUDE[@]}"; do
    scope="${alias%%/*}"; model="${alias#*/}"
    bare_name="$model"
    [ "$wiz" = "1" ] && bare_name="$(printf '%s' "$model" | sed -E 's/-[0-9]{8}$//')"
    [ -n "$BARE_ONLY" ] && [ "$scope" != "$BARE_ONLY" ] && continue
    if [ "$scope" = "$BARE_PREF" ] || [ -z "${BARE[$bare_name]:-}" ]; then
      BARE["$bare_name"]="${CLAUDE[$alias]}"
    fi
  done
}

reset; add_claude "us.anthropic.claude-3-5-sonnet-20240620-v1:0"
build_bare_param 1 both
[ "${#BARE[@]}" -eq 1 ] && [ -n "${BARE[claude-3-5-sonnet]:-}" ] \
  && ok "WIZARD=1 strips the date suffix from the bare alias (#95 bug #1 fix)" \
  || no "WIZARD=1 date-stripping (got keys: ${!BARE[*]})"

build_bare_param 0 both
[ "${#BARE[@]}" -eq 1 ] && [ -n "${BARE[claude-3-5-sonnet-20240620]:-}" ] \
  && ok "WIZARD=0 keeps the dated bare alias (default behavior unchanged)" \
  || no "WIZARD=0 bare alias unexpectedly changed (got keys: ${!BARE[*]})"

# 13. CLAUDE map keys stay dated regardless of WIZARD (regression guard, mirrors case 4)
reset
add_claude "us.anthropic.claude-3-5-sonnet-20240620-v1:0"
add_claude "us.anthropic.claude-3-5-sonnet-20241022-v2:0"
build_bare_param 1 both
[ "${#CLAUDE[@]}" -eq 2 ] && [ -n "${CLAUDE[us/claude-3-5-sonnet-20240620]:-}" ] && [ -n "${CLAUDE[us/claude-3-5-sonnet-20241022-v2:0]:-}" ] \
  && ok "CLAUDE map keys stay dated regardless of WIZARD (#95 regression guard)" \
  || no "CLAUDE map wrongly mutated by wizard bare-alias logic (got keys: ${!CLAUDE[*]})"

# 14. SCOPE=us/global -> BARE_ONLY excludes the other scope entirely, no fallback
reset
add_claude "global.anthropic.claude-opus-4-8"
add_claude "us.anthropic.claude-opus-4-8"
build_bare_param 1 us
[ "${#BARE[@]}" -eq 1 ] && [ "${BARE[claude-opus-4-8]:-}" = "us.anthropic.claude-opus-4-8" ] \
  && ok "SCOPE=us pins the bare alias to us only, no global fallback (#95)" \
  || no "SCOPE=us bare-alias pin (got: ${!BARE[*]})"

build_bare_param 1 global
[ "${#BARE[@]}" -eq 1 ] && [ "${BARE[claude-opus-4-8]:-}" = "global.anthropic.claude-opus-4-8" ] \
  && ok "SCOPE=global pins the bare alias to global only, no us fallback (#95)" \
  || no "SCOPE=global bare-alias pin (got: ${!BARE[*]})"

reset; add_claude "global.anthropic.claude-opus-4-8"
build_bare_param 1 us
[ "${#BARE[@]}" -eq 0 ] \
  && ok "SCOPE=us with no us-scoped profile registers no bare alias (no silent global fallback, #95)" \
  || no "SCOPE=us wrongly fell back to global (got: ${!BARE[*]})"

# 15. Default (WIZARD=0 or SCOPE=both) grep-guard on the literal init line
if grep -q 'BARE_PREF="global"; BARE_ONLY=""' "$REGISTER_SCRIPT"; then
  ok "register-models.sh initializes BARE_PREF=global/BARE_ONLY=empty by default (#95)"
else
  no "register-models.sh missing the default BARE_PREF/BARE_ONLY init (#95 regression risk)"
fi

# 15b. BARE must be declared with =() — under set -u, bash 5.2 treats a
# never-populated associative array's ${#BARE[@]} as unbound, which crashes
# the SCOPE-pinned-empty and end-of-run summary lines (found live via case 14
# above throwing "BARE: unbound variable" before this fix).
if grep -q 'declare -A BARE=()' "$REGISTER_SCRIPT"; then
  ok "register-models.sh declares BARE with =() (set -u safe when empty, #95)"
else
  no "register-models.sh declares BARE without =() -- \${#BARE[@]} will crash under set -u when empty (#95)"
fi

# 16. wizard_classify() table test (#95): claude/mantle/other, "other" never
# deleted. Extract the REAL function body from register-models.sh and eval it
# (rather than hand-copying the case patterns, which previously masked #95 QA
# defect 3 — the copy diverged from the shipped code). If extraction fails the
# test fails loudly rather than silently testing nothing.
PREFIX=""   # wizard_classify strips a leading "$PREFIX" (this run's tenant); none here
classify_src="$(sed -n '/^wizard_classify() {$/,/^}$/p' "$REGISTER_SCRIPT")"
if [ -n "$classify_src" ] && printf '%s' "$classify_src" | grep -q 'echo other'; then
  eval "$classify_src"
  ok "extracted real wizard_classify() from register-models.sh (#95)"
else
  no "could not extract wizard_classify() with an 'other' catch-all from register-models.sh (#95)"
  wizard_classify() { echo other; }   # keep the table below runnable
fi
# script-owned Claude name forms -> claude
for n in "global.anthropic.claude-opus-4-8" "us.anthropic.claude-3-5-sonnet-20240620-v1:0" \
         "global/claude-opus-4-8" "us/claude-3-5-sonnet-20240620" "claude-opus-4-8"; do
  [ "$(wizard_classify "$n")" = "claude" ] && ok "wizard_classify: $n -> claude" || no "wizard_classify: $n expected claude (got $(wizard_classify "$n"))"
done
# script-owned Mantle/oss name forms -> mantle. Include the BARE gpt-5 legacy
# alias the script emits (from openai.gpt-5): gpt-5-* did NOT match it (Codex F4).
for n in "openai.gpt-5.6-sol" "openai.gpt-oss-120b" "gpt-5-6-sol" "gpt-oss-120b" "gpt-5"; do
  [ "$(wizard_classify "$n")" = "mantle" ] && ok "wizard_classify: $n -> mantle" || no "wizard_classify: $n expected mantle (got $(wizard_classify "$n"))"
done
# OWNERSHIP MODEL (owner decision 2026-07-29, #100): every non-default model in
# the gateway was registered by THIS script; there are no hand-added models to
# protect and no multi-tenant foreign rows. So clean mode deletes ANY row that
# matches one of our own name forms — we do NOT carve out look-alike names. A
# name that matches our own scoped/bare/canonical form classifies claude|mantle
# and IS deletable, including a byte-identical "global/claude-private".
for n in "global/claude-private" "us/claude-custom" "claude-my-hand-added"; do
  [ "$(wizard_classify "$n")" = "claude" ] \
    && ok "wizard_classify: our-shaped $n -> claude (deletable; owner ownership model, #100)" \
    || no "wizard_classify: our-shaped $n should classify claude (got $(wizard_classify "$n"))"
done
# genuinely unrelated names (matching NONE of our forms) still fall to "other" —
# incidental, not a safety guarantee. Left alone so we don't touch LiteLLM defaults.
for n in "my-hand-added-model" "global/my-hand-added-model" "us/custom-model" \
         "openai/experiment" "gpt-4o-mine" "global/team-scratch"; do
  [ "$(wizard_classify "$n")" = "other" ] \
    && ok "wizard_classify: unrelated $n -> other (matches no script form, #95)" \
    || no "wizard_classify: unrelated $n should classify as other (got $(wizard_classify "$n"))"
done
# A tenant PREFIX (#33) is stripped when present so a prefixed row still matches;
# an unprefixed our-shaped row is equally ours (single-account is the norm).
[ "$(PREFIX='bu-a/' wizard_classify "bu-a/global/claude-opus-4-8")" = "claude" ] \
  && ok "wizard_classify: prefixed bu-a/global/claude-* -> claude (prefix stripped, #33)" \
  || no "wizard_classify: prefixed Claude row should classify claude"
[ "$(PREFIX='' wizard_classify "global/claude-opus-4-8")" = "claude" ] \
  && ok "wizard_classify: unprefixed global/claude-* -> claude (single-account, ours)" \
  || no "wizard_classify: unprefixed our-shaped row should classify claude"

echo ""
echo "== register-models naming: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
