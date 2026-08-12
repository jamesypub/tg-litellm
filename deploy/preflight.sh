#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&B||C idiom is intentional; reporters never fail
# Preflight checks before installing — catches the common clean-account failures.
#
#   AWS_PROFILE=<profile> ./preflight.sh <env>     (or: ./deploy.sh <env> preflight)
#
# Verifies: required tools, AWS identity, account/region, tfvars completeness,
# AZ validity, TLS choice consistency, and required secrets for Codex (if used).
cd "$(dirname "$0")" || exit
. ./lib.sh
tg_init "${1:-}"

ok=0; warn=0; err=0
pass(){ echo "  ok   $1"; ok=$((ok+1)); }
note(){ echo "  warn $1"; warn=$((warn+1)); }
bad(){  echo "  ERR  $1"; err=$((err+1)); }

echo "== tools =="
for t in aws python3 curl; do command -v "$t" >/dev/null 2>&1 && pass "$t present" || bad "$t missing"; done
"$TF" version >/dev/null 2>&1 && pass "terraform present ($TF)" || bad "terraform missing"

echo "== aws identity / region =="
aws sts get-caller-identity >/dev/null 2>&1 && pass "AWS credentials valid ($AWS_PROFILE)" || bad "AWS credentials invalid for $AWS_PROFILE"
# region must be a real region
if aws ec2 describe-regions --region-names "$REGION" >/dev/null 2>&1; then pass "region $REGION valid"; else bad "region $REGION invalid/unavailable"; fi

echo "== tfvars =="
for key in region tenant env azs alb_ingress_cidrs ui_password; do
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS"; then pass "$key set"; else bad "$key missing in $TFVARS"; fi
done
# env in tfvars should match the workspace/arg
tv_env="$(tfvars_get "$TFVARS" env)"
[ "$tv_env" = "$ENV" ] && pass "tfvars env matches ($ENV)" || note "tfvars env='$tv_env' != arg '$ENV'"

echo "== ALB ingress =="
if grep -qE '^[[:space:]]*alb_ingress_cidrs[[:space:]]*=.*(0\.0\.0\.0/0|REPLACE_)' "$TFVARS"; then
  bad "alb_ingress_cidrs contains a public network or unresolved placeholder"
else
  ingress_cidrs="$(sed -n 's/^[[:space:]]*alb_ingress_cidrs[[:space:]]*=[[:space:]]*\[\(.*\)\].*/\1/p' "$TFVARS" | tr -d '" ')"
  [ -n "$ingress_cidrs" ] && pass "ALB ingress allowlist configured ($ingress_cidrs)" || bad "could not parse alb_ingress_cidrs from $TFVARS"
fi

echo "== availability zones =="
# extract AZs from the azs = [...] line and validate each exists in the region
AZS="$(sed -n 's/^[[:space:]]*azs[[:space:]]*=[[:space:]]*\[\(.*\)\].*/\1/p' "$TFVARS" | tr -d '" ' )"
if [ -n "$AZS" ]; then
  valid_azs="$(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[].ZoneName' --output text 2>/dev/null)"
  n=0
  IFS=',' read -ra A <<< "$AZS"
  for az in "${A[@]}"; do
    [ -z "$az" ] && continue; n=$((n+1))
    echo "$valid_azs" | tr '\t' '\n' | grep -qx "$az" && pass "AZ $az valid" || bad "AZ $az not in $REGION"
  done
  [ "$n" -ge 2 ] && pass "≥2 AZs" || bad "need ≥2 AZs (found $n)"
else
  bad "could not parse azs from $TFVARS"
fi

echo "== unresolved placeholders / example values (must be replaced) =="
# Hard-fail if the operator left example/placeholder values in an ACTIVE tfvars
# line — these would deploy an insecure or broken stack. (#11) Comment lines are
# skipped: the shipped example intentionally shows a commented bring-your-own-key
# block with placeholder ARNs, which is guidance, not an unresolved value. (#61)
ph_hits="$(grep -vE '^[[:space:]]*#' "$TFVARS" | grep -nE 'REPLACE[_-]|<ACCOUNT_ID>|<TENANT>|<ENV>|XXXXXX|ChangeMe' || true)"
if [ -n "$ph_hits" ]; then
  bad "unresolved placeholders in $TFVARS — replace these before installing:"
  echo "$ph_hits" | sed 's/^/       /'
else
  pass "no unresolved placeholders in $TFVARS"
fi
# The published example admin password must never reach a deployment.
uipw="$(tfvars_get "$TFVARS" ui_password)"
case "$uipw" in
  ""|REPLACE*|ChangeMe*) bad "ui_password is unset or still the example value — set a strong password" ;;
  *) pass "ui_password set (non-example)" ;;
esac

echo "== local secret-file permissions =="
# tfvars + local Terraform state hold plaintext control-plane secrets (master key,
# DB/UI passwords, CloudFront origin secret). Fail if any is group/world-readable
# so other local users can't read them. (#25)
perm_bad=0
check_perms() { # $1 = path glob description, $2.. = files
  local f mode
  for f in "$@"; do
    [ -e "$f" ] || continue
    mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)"
    # last two octal digits = group + other; must be 0 (no group/other access)
    case "$mode" in
      *00) : ;;                       # e.g. 600, 700 — owner-only, ok
      *)   bad "world/group-readable secret file: $f (mode $mode) — run: chmod 600 $f"; perm_bad=1 ;;
    esac
  done
}
check_perms "tfvars" "$TFVARS"
# local state (+ backups) under the workspace dir
if [ -d terraform.tfstate.d ]; then
  # shellcheck disable=SC2046
  check_perms "state" $(find terraform.tfstate.d -type f -name 'terraform.tfstate*' 2>/dev/null)
fi
[ "$perm_bad" -eq 0 ] && pass "tfvars + local state are owner-only (not group/world-readable)"

echo "== TLS choice =="
plaintext="$(tfvars_get "$TFVARS" allow_plaintext_alb)"
cert="$(tfvars_get "$TFVARS" acm_certificate_arn)"
if [ "$plaintext" = "true" ]; then note "allow_plaintext_alb=true (HTTP-only — quick-start; harden to HTTPS/CloudFront before production)"
elif [ -n "$cert" ]; then pass "HTTPS: acm_certificate_arn set"
else bad "TLS: set acm_certificate_arn OR allow_plaintext_alb=true"; fi

echo "== Codex feature (enable_codex) =="
# Explicit feature switch (#40.4): Claude-only installs need NO Codex secret and
# must not have to delete a placeholder. Only when enable_codex=true do we REQUIRE
# and validate the credential + refresher config (fail-closed).
codex="$(tfvars_get "$TFVARS" enable_codex)"
# enable_codex now DEFAULTS to true (#61): an unset value means Codex-on.
if [ "$codex" = "true" ] || [ -z "$codex" ]; then
  pass "enable_codex = true (default; Codex/gpt-5.x Responses route will be validated)"
  # (#76) codex_key_mode is the front door for the key strategy. Unset => the
  # Terraform default (lambda_auto_refresh). Validate the value here so a typo is
  # caught in preflight, not mid-apply, and so the checks below can be mode-aware.
  mode="$(tfvars_get "$TFVARS" codex_key_mode)"; mode="${mode:-lambda_auto_refresh}"
  case "$mode" in
    lambda_auto_refresh)        pass "codex_key_mode = lambda_auto_refresh (default; key re-minted by the built-in Lambda)" ;;
    external_cron_auto_refresh) pass "codex_key_mode = external_cron_auto_refresh (no TF refresher; you manage the BYO key via your own cron)" ;;
    *)                          bad "codex_key_mode must be one of: lambda_auto_refresh, external_cron_auto_refresh (got: '$mode')" ;;
  esac
  # 1) BEDROCK_API_KEY: the installer AUTO-MINTS this now (#61). An UNSET ARN on a
  # fresh Codex-on install is the EXPECTED path — Terraform creates the secret and
  # deploy.sh mints the initial token into it. Only fail if the operator EXPLICITLY
  # supplied an ARN that doesn't resolve/exist (bring-your-own-key mistake).
  # Only consider ACTIVE (uncommented) lines — the shipped example carries a
  # commented BYO block whose placeholder ARN must not be read as wired. (#61)
  arn="$(grep -vE '^[[:space:]]*#' "$TFVARS" | sed -n 's/.*BEDROCK_API_KEY[^"]*"\([^"]*\)".*/\1/p' | head -1)"
  case "$arn" in
    arn:aws:secretsmanager:*)
      if aws secretsmanager describe-secret --secret-id "$arn" >/dev/null 2>&1; then
        pass "BEDROCK_API_KEY secret exists (operator-supplied key)"
      else
        bad "BEDROCK_API_KEY ARN set but the secret does not exist in this account/region: $arn"
      fi ;;
    "") pass "BEDROCK_API_KEY will be minted + created by the installer (Codex on-by-default, #61 — no manual secret)" ;;
    *)  bad "BEDROCK_API_KEY is set but unresolved ($arn) — either set a real Secrets Manager ARN or remove it to let the installer mint one" ;;
  esac
  # 2) Key-rotation config. In external_cron_auto_refresh mode there is NO TF
  # refresher (the operator's own cron re-mints the BYO key), so refresh-off is
  # EXPECTED there. lambda_auto_refresh needs rotation on (~12h key TTL). (#76)
  refresh="$(tfvars_get "$TFVARS" enable_codex_key_refresh)"
  if [ "$mode" = "external_cron_auto_refresh" ]; then
    # external_cron_auto_refresh deploys no TF refresher — the gateway reads a
    # caller-supplied key ARN that the operator's own cron re-mints (or a durable
    # key). No BYO/override ARN => misconfiguration. (#69)
    if [ -n "$arn" ]; then
      pass "external_cron_auto_refresh: gateway wired to operator-supplied key ($arn); no TF refresher (you run your own cron — see docs/codex-cron-key-refresh.md)"
    else
      bad "codex_key_mode=external_cron_auto_refresh needs a key ARN: set gateway_extra_secrets.BEDROCK_API_KEY (or codex_key_secret_arn) to a Secrets Manager ARN your own cron re-mints a short-term key into (#69, docs/codex-cron-key-refresh.md)."
    fi
  elif [ "$refresh" = "false" ]; then
    bad "enable_codex is on (mode=$mode) but enable_codex_key_refresh=false — the minted Bedrock API key expires ~12h. Leave it at the default (true), or set codex_key_mode=external_cron_auto_refresh to manage the key with your own cron."
  else
    pass "enable_codex_key_refresh = true (default; installer-minted key auto-rotates)"
    # (#70) The lambda_auto_refresh engine is a Lambda. Some org SCPs deny
    # lambda:CreateFunction; a DEFAULT Codex-on apply would then blow up MID-APPLY
    # with a raw AWS error. Probe the permission up front (only when the Lambda will
    # actually be created: lambda_auto_refresh mode AND no bring-your-own key) and
    # fail closed here with an actionable remedy instead. Uses
    # iam:SimulatePrincipalPolicy — a read-only capability check that creates nothing.
    if [ "$mode" = "lambda_auto_refresh" ] && [ -z "$arn" ]; then
      caller_arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
      if [ -n "$caller_arn" ] && [ "$caller_arn" != "None" ]; then
        sim="$(aws iam simulate-principal-policy \
                 --policy-source-arn "$caller_arn" \
                 --action-names lambda:CreateFunction \
                 --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null || true)"
        case "$sim" in
          allowed)
            pass "lambda:CreateFunction permitted — Codex key refresher can deploy" ;;
          explicitDeny|implicitDeny)
            bad "your org SCP/policy blocks lambda:CreateFunction (SimulatePrincipalPolicy: $sim) — the lambda_auto_refresh engine cannot deploy. Switch to codex_key_mode=external_cron_auto_refresh (BYO key via gateway_extra_secrets.BEDROCK_API_KEY, re-minted by your own cron — see docs/codex-cron-key-refresh.md, #69); or set enable_codex=false for a Claude-only install." ;;
          *)
            note "could not determine lambda:CreateFunction permission (SimulatePrincipalPolicy unavailable: '${sim:-none}') — if apply fails creating the refresher Lambda, your org likely blocks it; use codex_key_mode=external_cron_auto_refresh (#69)" ;;
        esac
      else
        note "skipped lambda:CreateFunction SCP probe (could not resolve caller identity)"
      fi
    fi
  fi
elif [ "$codex" = "false" ]; then
  pass "Codex disabled (enable_codex = false) — Claude-only; no Codex secret required"
  # Guard against a half-configured Claude-only install: an ACTIVE (uncommented)
  # BEDROCK_API_KEY line with an unresolved placeholder ARN would break apply.
  if grep -qE '^[[:space:]]*BEDROCK_API_KEY[[:space:]]*=' "$TFVARS" \
     && grep -E '^[[:space:]]*BEDROCK_API_KEY[[:space:]]*=' "$TFVARS" | grep -qE '<ACCOUNT_ID>|<TENANT>|<ENV>|XXXXXX|\$ACCOUNT_ID'; then
    bad "enable_codex is not true but an active BEDROCK_API_KEY line still has an unresolved placeholder — comment it out or set enable_codex=true with a real ARN"
  fi
else
  bad "enable_codex must be true or false (got: '$codex')"
fi

echo ""
echo "== preflight: $ok ok, $warn warn, $err error =="
[ "$err" -eq 0 ] || { echo "Fix the ERR items before installing."; exit 1; }
echo "Ready. Next: ./deploy.sh $ENV plan   (then apply/install)"
