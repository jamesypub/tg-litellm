#!/usr/bin/env bash
# Offline regression tests for the #40/#41/#39 installer + handoff work. Runs with
# NO network/AWS/container so fail-closed / route / placeholder / handoff
# regressions fail BEFORE publish, not only via QA's live run.
#
#   ./tests/installer-regression.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0; fail=0
ok()  { echo "  PASS $1"; pass=$((pass+1)); }
no()  { echo "  FAIL $1"; fail=$((fail+1)); }
# assert file $1 matches regex $2
has()   { grep -qE "$2" "$1" && ok "$3" || no "$3 (missing: $2 in $1)"; }
hasnt() { grep -qE "$2" "$1" && no "$3 (found: $2 in $1)" || ok "$3"; }

echo "== #40.1: install runs preflight automatically, before apply =="
# preflight invocation must appear before the do_apply call in the install case.
awk '/install\)/{ins=1} ins&&/preflight\.sh/{print "PRE";exit} ins&&/do_apply/{print "APPLY";exit}' deploy/deploy.sh \
  | head -1 | grep -qx PRE && ok "preflight precedes apply in install" || no "preflight must precede apply in install"

echo "== #40.1/#40.2: fail-closed — no unconditional 'Install complete' after a swallowed failure =="
# register-models must be hard (|| exit / ERROR), not the old informational-message swallow.
has deploy/deploy.sh 'register-models\.sh[^|]*\\?[[:space:]]*$|register-models\.sh.*' "register-models is invoked"
hasnt deploy/deploy.sh "register-models reported issues — re-run" "old swallowed-registration message removed"
# 'Install complete' must be reachable only after the fail-closed stages (guarded by exits above).
has deploy/deploy.sh 'Install complete — all required stages passed' "success banner is the fail-closed one"
has deploy/deploy.sh 'model registration failed.*aborting' "registration failure aborts"
has deploy/deploy.sh 'incomplete set \(Codex may be missing\).*aborting' "model-visibility gate aborts on an incomplete served set (#53 R2/#62)"
has deploy/deploy.sh 'route verification failed.*aborting' "route verification failure aborts"

echo "== #40.3: verify.sh route selection (Claude=Messages, Codex=Responses) =="
has deploy/verify.sh '/v1/messages' "Claude uses /v1/messages"
has deploy/verify.sh '/v1/responses' "Codex uses /v1/responses"
# No ACTUAL request uses chat/completions (comments explaining the anti-pattern are fine).
grep -E '(curl|GW).*chat/completions' deploy/verify.sh >/dev/null 2>&1 \
  && no "Codex/Claude request must not use chat/completions" \
  || ok "no chat/completions request in verify.sh (comment mentions OK)"
has deploy/verify.sh 'enable_codex.*=.*1|CODEX_ENABLED=1' "Codex gated on enable_codex"
# #72: Codex verify policy — cred/model/region-not-ready is a WARNING (Claude still
# passes); only a configured-but-erroring route fails closed.
has deploy/verify.sh 'Codex not ready \(HTTP' "Codex not-ready (400/401/403/404) is a loud warning, not a fail (#72)"
has deploy/verify.sh '400\|401\|403\|404' "verify.sh branches on not-ready HTTP statuses (#72)"
has deploy/verify.sh 'configured \+ reachable but erroring' "Codex configured-but-erroring (5xx/malformed) still fails closed (#72)"
has deploy/verify.sh 'PASS \(Claude OK; Codex NOT READY' "verify PASSES with a Codex-not-ready warning banner (#72)"
hasnt deploy/verify.sh 'Codex Responses call failed \(enable_codex=true\): .*fail=1' "old unconditional Codex fail-closed removed (#72)"

echo "== #40.4/#61: enable_codex declared; Claude-only still selectable =="
has deploy/variables.tf 'variable "enable_codex"' "enable_codex variable declared"
# The Codex secret block in the example must be commented out (not active) by default.
hasnt deploy/env.tfvars.example '^gateway_extra_secrets = \{' "no active Codex secret block by default"
has deploy/preflight.sh 'enable_codex.*true' "preflight handles Codex-on"
has deploy/preflight.sh 'Claude-only' "preflight still supports explicit Claude-only (enable_codex=false)"

echo "== #61: Codex on-by-default + installer auto-mints the Bedrock key =="
# Defaults flipped to true (Terraform + sample).
has deploy/variables.tf 'default     = true' "enable_codex defaults to true (variables.tf)"
has deploy/env.tfvars.example '^enable_codex             = true' "sample ships enable_codex = true"
has deploy/env.tfvars.example '^enable_codex_key_refresh = true' "sample ships refresher on"
# The old hard requirement (must pre-wire a BEDROCK_API_KEY ARN) is GONE.
hasnt deploy/variables.tf 'requires gateway_extra_secrets.BEDROCK_API_KEY' "no pre-wired-ARN hard requirement remains"
# Terraform owns the secret so a single destroy tears it down (fresh-rebuild clean).
has deploy/codex-secret.tf 'resource "aws_secretsmanager_secret" "bedrock_api_key"' "Terraform owns the BEDROCK_API_KEY secret (#61)"
has deploy/codex-secret.tf 'recovery_window_in_days = 0' "secret has no recovery window (clean fresh rebuild)"
has deploy/codex-secret.tf 'output "bedrock_api_key_secret_arn"' "resolved secret ARN is output for the installer"
# Installer mints the initial token post-apply and writes it, fail-closed.
has deploy/deploy.sh 'minting initial Codex/Mantle Bedrock API key' "installer mints the initial key (#61)"
has deploy/deploy.sh 'put-secret-value --secret-id "\$BAK_ARN"' "installer writes the minted key to the TF-owned secret"
has deploy/deploy.sh 'failed to mint the Bedrock API key' "mint step is fail-closed"
# Preflight: unset ARN on a fresh Codex-on install is expected, not an error.
has deploy/preflight.sh 'will be minted \+ created by the installer' "preflight treats unset ARN as the auto-mint path (#61)"
# #70: preflight probes lambda:CreateFunction (SCP block) before apply, fail-closed with remedy.
has deploy/preflight.sh 'simulate-principal-policy' "preflight probes lambda:CreateFunction via SimulatePrincipalPolicy (#70)"
has deploy/preflight.sh 'action-names lambda:CreateFunction' "preflight targets the lambda:CreateFunction capability (#70)"
has deploy/preflight.sh 'blocks lambda:CreateFunction' "preflight fails closed with an SCP-block remedy message (#70)"
has deploy/preflight.sh 'explicitDeny\|implicitDeny' "preflight treats deny decisions as a hard failure (#70)"
# The probe must only run when the refresher will actually be created (no BYO key).
has deploy/preflight.sh '"\$mode" = "lambda_auto_refresh" \] && \[ -z "\$arn" \]' "preflight SCP probe gated on lambda_auto_refresh + no bring-your-own key (#70/#76)"
# Docs describe the working path (Codex on, auto-minted), not the old opt-in.
has docs/installer.md 'Codex works out of the box' "installer §5 documents Codex-on-by-default"
hasnt docs/installer.md 'only if .enable_codex = true.' "§5 no longer framed as opt-in-only"

echo "== #40.5/#42: executable doc snippets have no angle placeholders (fenced + INLINE, incl. root) =="
angle_hits=0
for f in README.md INSTALL.md docs/installer.md docs/client-setup.md docs/admin.md deploy/README.md; do
  # scan fenced bash/toml/sh blocks AND inline `backtick` commands for shell-
  # redirection-shaped <UPPER/lower> placeholders in an executable context (#42).
  if python3 - "$f" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
bad=[]
# fenced executable blocks
for m in re.finditer(r'```(?:bash|sh|toml)\n(.*?)```', s, re.S):
    for ln in m.group(1).splitlines():
        if ln.lstrip().startswith('#'): continue   # comments aren't executed
        if re.search(r'<[A-Za-z_][A-Za-z0-9_-]*>', ln): bad.append(ln.strip())
# inline `...` spans that look like a shell command (contain a command + an angle token)
for m in re.finditer(r'`([^`]+)`', s):
    span=m.group(1)
    if re.search(r'<[A-Za-z_][A-Za-z0-9_-]*>', span) and re.search(r'(\./|AWS_PROFILE=|deploy\.sh|curl |terraform )', span):
        bad.append(span.strip())
sys.exit(1 if bad else 0)
PY
  then :; else angle_hits=$((angle_hits+1)); echo "     angle placeholder in $f"; fi
done
[ "$angle_hits" -eq 0 ] && ok "no angle placeholders in executable doc snippets (fenced + inline)" || no "angle placeholders remain in $angle_hits file(s)"

echo "== naming: no 'trial' wording in publishable files (production framing) =="
grep -rniE '\\btrial\\b' README.md INSTALL.md docs/ deploy/*.md deploy/*.tf deploy/*.sh deploy/env.tfvars.example 2>/dev/null | grep -v node_modules >/dev/null \
  && no "'trial' still present in publishable files" || ok "no 'trial' wording in publishable files"

echo "== #40.6: one authoritative migration behavior (auto-run; command is break-glass) =="
has docs/installer.md 'migrations run automatically' "installer.md: migrations auto-run"
has deploy/README.md 'Migrations run automatically' "README: migrations auto-run"
hasnt deploy/README.md 'Run the migration task printed as .migration_run_command. output .once.' "README no longer says run migrations manually"
has deploy/README.md 'break-glass' "README frames migration_run_command as break-glass"

echo "== #40.7: install emits non-secret handoff metadata =="
has deploy/deploy.sh 'write_handoff' "install calls write_handoff"
has deploy/deploy.sh 'tg-llmgateway/handoff@1' "handoff schema present"
has deploy/deploy.sh 'secret_references' "handoff carries secret references only"
hasnt deploy/deploy.sh 'ANTHROPIC_AUTH_TOKEN.*MK|master.*key.*value.*handoff' "handoff writer does not emit key values"

echo "== #40/#41: admin renders complete developer package; developer only pastes =="
has deploy/render-handoff.sh 'claude-lg-' "renderer emits Claude launcher"
has deploy/render-handoff.sh 'codex-lg-' "renderer emits Codex launcher"
has deploy/render-handoff.sh 'model_catalog_json' "renderer emits Codex catalog reference"
has deploy/render-handoff.sh 'CLAUDE_CONFIG_DIR' "renderer isolates Claude config dir"
has deploy/render-handoff.sh 'wire_api = "responses"' "renderer Codex uses Responses"
# developer guide must NOT tell developers to curl-discover / generate a catalog
hasnt docs/client-setup.md 'make-codex-catalog\.sh <' "client-setup does not have developers run catalog gen with placeholders"
has docs/client-setup.md 'You do not configure anything by hand' "client-setup is paste-and-launch"

echo "== #39: managed-settings detection + container alternative + route-vs-CLI =="
has deploy/check-claude-managed-settings.sh 'managed-settings.json' "managed-settings check exists"
has deploy/check-claude-managed-settings.sh 'exit 3' "managed-settings check fails with remediation"
has docs/client-setup.md 'container' "container alternative documented"
has docs/client-setup.md 'does NOT prove Claude Code works' "route-success != CLI-success documented"

# ===================== #41 first-round FAIL fixes (#42-#50) =====================

echo "== #50: no secret in curl argv (scripts + docs) =="
grep -rnE '\-H "(Authorization: Bearer|x-api-key:) \$' deploy/*.sh docs/*.md >/dev/null 2>&1 \
  && no "secret-bearing -H found in argv" || ok "no secret-bearing -H in argv (uses tg_curl/--config)"
has deploy/lib.sh 'tg_curl' "lib.sh provides secret-safe tg_curl"
grep -qF -e '--config' deploy/render-handoff.sh && ok "renderer authenticates via curl --config" || no "renderer should use curl --config"
# admin.md is now pointer + UI-flow (no curl scripts) — assert it has no
# secret-bearing curl argv rather than requiring the old --config script.
grep -qE '\-H "(Authorization: Bearer|x-api-key:) \$' docs/admin.md \
  && no "admin.md must not expose a secret in curl argv" \
  || ok "admin.md has no secret-bearing curl argv (pointer + UI flow)"
has docs/admin.md 'docs.litellm.ai/docs/proxy/ui' "admin.md points to upstream LiteLLM admin docs"

echo "== #58: admin.md /team/new workaround cleans up its key file on failure =="
# The documented team-create snippet writes the master key to a curl --config file.
# It MUST remove that file even if curl fails (set -e + curl exit 7/non-2xx), or a
# key-bearing file lingers — the #50-class cleanup gap. Assert a trap guards it, and
# that the snippet does NOT rely on a bare trailing `rm` (which set -e skips on failure).
# The EXIT trap that removes the key file must be armed BEFORE the curl (so it
# fires even if curl aborts the script under set -e). awk records the trap line and
# the curl line, then asserts trap-line < curl-line and both present.
if awk '
  /trap .*rm -f .*CFG.*EXIT/ && !t {t=NR}
  /curl .*--config .*team\/new/ && !c {c=NR}
  END{exit !(t && c && t < c)}' docs/admin.md; then
  ok "#58 team-create snippet arms an EXIT trap (before curl) to remove the key file"
else
  no "#58 team-create snippet lacks an always-run EXIT trap armed before curl"
fi
# Functional: the documented pattern (trap … EXIT; write cfg; curl fails) still
# removes the cfg. Emulate curl exit 7 under set -e in a subshell.
T58="$(mktemp -d)"; trap 'rm -rf "$T58"' EXIT
cfg58="$(
  ( set -e
    CFG="$(mktemp -p "$T58")"; chmod 600 "$CFG"
    trap 'rm -f "$CFG"' EXIT
    printf 'header = "Authorization: Bearer sk-stub"\n' > "$CFG"
    ( exit 7 )                       # emulate curl -f connection/HTTP failure
    echo "$CFG"
  ) 2>/dev/null || true
)"
# after the subshell exits (trap fired), no key-bearing config should remain in T58
if find "$T58" -type f 2>/dev/null | grep -q .; then
  no "#58 key-config file survived a failed curl under set -e (cleanup not guaranteed)"
else
  ok "#58 key-config file removed even when curl fails under set -e (trap cleanup)"
fi

echo "== #43: renderer needs a key SOURCE, not an alias lookup =="
has deploy/render-handoff.sh '\-\-create' "renderer supports create-to-render"
has deploy/render-handoff.sh '\-\-key-file' "renderer supports one-time key file/stdin"
hasnt deploy/render-handoff.sh "info',\\{\\}\\).get\\('token'\\)" "renderer no longer recovers raw key from alias lookup"

echo "== #45: renderer selects a client-compatible (non-slash) Claude alias =="
has deploy/render-handoff.sh "grep -vE '/'" "renderer excludes slash/scope aliases for Claude"
has deploy/render-handoff.sh 'only slash/scope Claude aliases' "renderer fails closed on slash-only allowlist"
has docs/admin.md 'non-slash' "admin.md documents the non-slash Claude alias requirement (#45)"
has docs/admin.md 'create 50 claude-opus-4-8' "admin.md render example uses a non-slash Claude alias"

echo "== #95: clean-mode docs must NOT re-assert the withdrawn 'never delete hand-added' guarantee =="
# Owner withdrew the absolute never-delete-hand-added guarantee (#100). Fail if
# the old absolute claim drifts back into the shipped docs or the script header.
hasnt docs/admin.md '[Hh]and-added.*never (deleted|removed)' "admin.md drops the withdrawn hand-added never-delete claim (#95)"
hasnt deploy/register-models.sh 'hand-added.*NEVER deleted' "register-models.sh header drops the withdrawn hand-added never-delete claim (#95)"
# ...and must state the actual contract (names matching our forms are deletable).
has docs/admin.md "do not hand-register a model under one of the script's own" "admin.md states the real clean-mode ownership contract (#95)"

echo "== #47: launchers scrub provider env (no gateway bypass) =="
has deploy/render-handoff.sh 'CLAUDE_CODE_USE_BEDROCK' "Claude launcher neutralizes Bedrock selector"
has deploy/render-handoff.sh 'env -u CLAUDE_CODE_USE_BEDROCK' "Claude launcher runs child via scrubbed env"
has deploy/render-handoff.sh 'refusing to launch' "launcher fails closed on conflicting provider var"

echo "== #44: Codex catalog is generated + embedded (not a dangling reference) =="
has deploy/render-handoff.sh 'make-codex-catalog\.sh' "renderer invokes catalog generator"
has deploy/render-handoff.sh 'could not build a complete version-matched Codex catalog' "renderer fails closed without complete catalog"
has deploy/render-handoff.sh 'got.*want|got./.want' "renderer verifies catalog covers all allowlisted models (#44)"
hasnt deploy/render-handoff.sh 'delivered alongside this package' "no 'delivered alongside' dangling comment"

echo "== #48: container fallback pins the Claude version (baked at render) =="
has deploy/render-handoff.sh 'claude-code@\$CLAUDE_VER' "renderer bakes the concrete pinned Claude version into the container cmd"
has docs/client-setup.md '\-e CLAUDE_CODE_VERSION=' "client-setup container example passes the pinned version"

echo "== #49: TLS 1.2 minimum only claimed with a custom cert (default cert doesn't drift) =="
has deploy/cloudfront.tf 'cloudfront_acm_certificate_arn' "custom-cert variable exists"
has deploy/cloudfront.tf 'minimum_protocol_version = "TLSv1.2_2021"' "TLS1.2 min set on the custom-cert path"
# On the default-cert path, no minimum_protocol_version is declared (avoids drift).
python3 - <<'PY'
import sys
s=open('deploy/cloudfront.tf').read()
# Brace-parse the viewer_certificate blocks; the default-cert block must contain
# no minimum_protocol_version ASSIGNMENT (a settable line), which would drift.
def blocks(src, key):
    out=[]; i=0
    while True:
        j=src.find(key, i)
        if j<0: break
        k=src.find('{', j); depth=0; e=k
        for p in range(k, len(src)):
            if src[p]=='{': depth+=1
            elif src[p]=='}':
                depth-=1
                if depth==0: e=p; break
        out.append(src[j:e+1]); i=e+1
    return out
bad=False
for b in blocks(s, 'dynamic "viewer_certificate"'):
    if 'cloudfront_default_certificate = true' in b and 'minimum_protocol_version =' in b:
        bad=True
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] && ok "default-cert branch declares no (ineffective) TLS minimum" || no "default-cert branch still declares a minimum (will drift)"

echo "== #46: portable idle-timeout default (60) + ALB reconcile + FAQ + quota guidance =="
has deploy/cloudfront.tf 'default = 60' "cloudfront_origin_read_timeout default is 60 (portable; applies under any quota)"
has deploy/deploy.sh 'idle_timeout.timeout_seconds' "deploy.sh reconciles ALB idle timeout"
has docs/installer.md 'Connection closed mid-response' "streaming FAQ present"
has docs/installer.md 'request-service-quota-increase' "FAQ documents how to request a quota increase"
has deploy/cloudfront.tf 'output "cloudfront_origin_read_timeout"' "tf output declared for the reconcile (#46 R4)"
has deploy/deploy.sh 'output unavailable.*leaving ALB idle timeout unchanged' "reconcile skips (no stale constant) when output absent (#46 R4)"
hasnt deploy/deploy.sh 'echo 180' "no stale-180 fallback constant remains (#46 R4)"

echo "== R4 residual fixes (#43 docs / #44 version / #39 inline check / #50 cleanup) =="
has docs/admin.md '\-\-create 50' "admin.md render commands include a key source (#43 R4)"
has docs/admin.md '\-\-key-file' "admin.md documents the --key-file option (#43 R4)"
hasnt deploy/deploy.sh 'SUPPORTED_CODEX_VERSION="0.47.0"' "handoff no longer hard-codes stale Codex 0.47.0 (#44 R4)"
has deploy/deploy.sh 'codex --version' "handoff derives the real Codex version (#44 R4)"
hasnt deploy/render-handoff.sh './deploy/check-claude-managed-settings.sh' "package no longer calls the missing relative managed-check script (#39 R4)"
has deploy/lib.sh 'curl --config "\$cfg" "\$@" || rc=\$?' "tg_curl guards curl status so cleanup runs on forced failure (#50 R4)"

echo "== #61: published sample survives the preflight contract (inline comments + commented placeholders) =="
# Executable coverage for the two #62-blocking bugs: (1) tfvars_get must strip an
# inline comment so `enable_codex = true   # note` reads as bool true; (2) the
# preflight placeholder scan must ignore COMMENT lines so the shipped commented
# bring-your-own-key example (with an XXXXXX placeholder) isn't flagged.
( # subshell: sourcing lib.sh sets globals
  # shellcheck source=deploy/lib.sh
  . deploy/lib.sh
  ex="deploy/env.tfvars.example"
  ec="$(tfvars_get "$ex" enable_codex)"
  [ "$ec" = "true" ] && ok "tfvars_get strips inline comment: enable_codex -> 'true' (#61)" \
    || no "tfvars_get inline-comment strip: got '$ec' (expected true) (#61)"
   er="$(tfvars_get "$ex" enable_codex_key_refresh)"
  [ "$er" = "true" ] && ok "tfvars_get: enable_codex_key_refresh -> 'true' (#61)" \
    || no "tfvars_get: enable_codex_key_refresh got '$er' (#61)"
  # A quoted value with no comment still strips its quotes (regression guard).
  tf61="$(mktemp)"; printf 'x = "us-east-1"\ny = 7   # inline\n' > "$tf61"
  [ "$(tfvars_get "$tf61" x)" = "us-east-1" ] && ok "tfvars_get still unquotes plain quoted values" || no "tfvars_get broke quoted-value parsing"
  [ "$(tfvars_get "$tf61" y)" = "7" ] && ok "tfvars_get strips inline comment from a bare number" || no "tfvars_get number+comment parse"
  rm -f "$tf61"
)
# The example's commented BYO placeholder line must NOT trip the active-line scan.
grep -vE '^[[:space:]]*#' deploy/env.tfvars.example | grep -qE 'XXXXXX|<ACCOUNT_ID>' \
  && no "#61 commented BYO placeholder is being scanned as an active value" \
  || ok "#61 commented BYO placeholder is not flagged by the active-line scan"
has deploy/preflight.sh "grep -vE '\^\[\[:space:\]\]\*#' \"\\\$TFVARS\"" "preflight placeholder scan skips comment lines (#61)"

# Exercise the EXACT Codex-gate extractors preflight uses, against a filled sample
# (only the 3 required operator values replaced) — the complete branch QA runs.
( # subshell
  # shellcheck source=deploy/lib.sh
  . deploy/lib.sh
  tf="$(mktemp)"
  sed -e 's#REPLACE_WITH_YOUR_PUBLIC_IP/32#203.0.113.5/32#' \
      -e 's#REPLACE-with-a-strong-password#Str0ng-Pass-Example#' \
      deploy/env.tfvars.example > "$tf"
  # (a) enable_codex parses to a clean bool despite its inline comment
  c="$(tfvars_get "$tf" enable_codex)"
  [ "$c" = "true" ] && ok "filled sample: enable_codex parses 'true' (#61)" || no "filled sample enable_codex='$c'"
  # (b) the BYO-ARN extractor (preflight.sh:122) reads NO active ARN — the only
  #     BEDROCK_API_KEY line is commented, so the installer-mint path is taken.
  arn="$(grep -vE '^[[:space:]]*#' "$tf" | sed -n 's/.*BEDROCK_API_KEY[^"]*"\([^"]*\)".*/\1/p' | head -1)"
  [ -z "$arn" ] && ok "filled sample: no active BYO BEDROCK_API_KEY ARN (auto-mint path, #61)" || no "filled sample reads a phantom active ARN: '$arn'"
  # (c) no unresolved placeholders remain on active lines after the 3 replacements
  ph="$(grep -vE '^[[:space:]]*#' "$tf" | grep -nE 'REPLACE[_-]|<ACCOUNT_ID>|<TENANT>|<ENV>|XXXXXX|ChangeMe' || true)"
  [ -z "$ph" ] && ok "filled sample: no unresolved active placeholders (#61)" || { no "filled sample still has active placeholders"; echo "$ph" | sed 's/^/       /'; }
  rm -f "$tf"
)
# Guard the fix: the BYO-ARN extractor must skip comment lines.
has deploy/preflight.sh "grep -vE '\^\[\[:space:\]\]\*#' \"\\\$TFVARS\" \| sed -n" "preflight BYO-ARN extractor skips comment lines (#61)"

echo "== #76: codex_key_mode selector (names the key-refresh process; two modes) =="
# The selector variable exists with the two process-named values + a default.
has deploy/variables.tf 'variable "codex_key_mode"' "codex_key_mode variable declared"
has deploy/variables.tf 'default     = "lambda_auto_refresh"' "codex_key_mode defaults to lambda_auto_refresh (today's behavior)"
has deploy/variables.tf 'contains\(\["lambda_auto_refresh", "external_cron_auto_refresh"\]' "unknown mode rejected with the two valid values"
# Modes name the refresh PROCESS, not key lifespan — no long_term_key / cron_auto_refresh.
hasnt deploy/variables.tf 'long_term_key' "long_term_key mode removed (lifespan is orthogonal to refresh process)"
hasnt deploy/variables.tf '"cron_auto_refresh"' "old cron_auto_refresh name removed (renamed to external_cron_auto_refresh)"
# The 1.9-only cross-variable validation in the enable_codex block is GONE
# (portability bug on the >=1.5 floor); the rule moved to a precondition.
hasnt deploy/variables.tf '!var.enable_codex \|\| var.enable_codex_key_refresh' "removed the TF>=1.9 cross-var validation from enable_codex (#71/#76)"
has deploy/codex-secret.tf 'resource "terraform_data" "codex_key_mode_guard"' "mode rule enforced via a plan-time precondition (TF>=1.4, 1.5-floor-safe)"
# external_cron_auto_refresh needs a BYO key ARN; lambda_auto_refresh needs rotation on.
has deploy/codex-secret.tf 'external_cron_auto_refresh.* requires a Secrets Manager key ARN' "external_cron_auto_refresh requires a BYO/override key ARN (#69)"
has deploy/codex-secret.tf 'lambda_auto_refresh.* needs the refresher on' "lambda_auto_refresh requires rotation on (~12h key)"
# Derivation: only lambda_auto_refresh runs the TF-managed refresher.
has deploy/codex-secret.tf 'codex_tf_managed_refresh = var.codex_key_mode == "lambda_auto_refresh"' "only lambda_auto_refresh runs a TF refresher"
# The Lambda engine only deploys for lambda_auto_refresh (not external_cron).
has deploy/codex-key-refresher.tf 'var.codex_key_mode == "lambda_auto_refresh"' "Lambda refresh engine gated on lambda_auto_refresh mode (#76)"
# Raw flags remain declared (back-compat).
has deploy/codex-key-refresher.tf 'variable "enable_codex_key_refresh"' "raw enable_codex_key_refresh still accepted (back-compat)"
# (#79) The Terraform-owned secret must NOT be created when a BYO key is supplied —
# creating it is unused AND collides (ResourceExistsException) on a same-named
# existing secret. Gate on the plan-time-known codex_byo_key_present.
has deploy/codex-secret.tf 'count = var.enable_codex && !local.codex_byo_key_present' "TF-owned secret skipped when a BYO key ARN is supplied (#79 collision fix)"

echo "== #70: preflight maps codex_key_mode + SCP-Lambda-block to the right remedy =="
has deploy/preflight.sh 'simulate-principal-policy' "preflight probes lambda:CreateFunction non-mutatingly (#70)"
has deploy/preflight.sh 'external_cron_auto_refresh' "SCP-Lambda-block remedy points at external_cron_auto_refresh"

echo "== HCL validity: terraform validate (real parse, not grep) =="
# The grep asserts above check TEXT; only `terraform validate` proves the HCL
# actually parses and cross-file references resolve. Cheap (~1s), no AWS creds.
# Runs wherever terraform is present; where it is ABSENT this is a HARD FAIL
# (never a silent skip) unless ALLOW_NO_TERRAFORM=1 is explicitly set.
TF_BIN="$(command -v terraform || command -v tofu || { [ -x "$HOME/bin/terraform" ] && echo "$HOME/bin/terraform"; } || true)"
if [ -n "$TF_BIN" ]; then
  if ( cd deploy && "$TF_BIN" init -backend=false -input=false >/tmp/tf-init.log 2>&1 \
        && "$TF_BIN" validate >/tmp/tf-validate.log 2>&1 ); then
    ok "terraform validate: configuration is valid"
  else
    no "terraform validate FAILED — see /tmp/tf-validate.log / /tmp/tf-init.log"
    tail -12 /tmp/tf-validate.log 2>/dev/null | sed 's/^/      /'
  fi
elif [ "${ALLOW_NO_TERRAFORM:-0}" = "1" ]; then
  echo "  warn terraform not found; ALLOW_NO_TERRAFORM=1 set — validate SKIPPED (grep-only coverage)"
else
  no "terraform not found — cannot validate HCL. Install terraform, or set ALLOW_NO_TERRAFORM=1 to acknowledge grep-only coverage."
fi

echo ""
echo "== installer-regression: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
