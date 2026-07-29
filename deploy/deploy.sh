#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&B||C idiom is intentional; reporters never fail
# LiteLLM AWS deploy — profile-driven, per-env Terraform state.
#
#   AWS_PROFILE=<profile> ./deploy.sh <env> <action>
#
# Actions:
#   preflight  check prerequisites (tools, identity, tfvars, AZs, cert/secrets)
#   plan       show what would change (no changes made)
#   apply      create/update infrastructure only
#   install    apply + grant-bedrock + register-models   (one-command install)
#   destroy    tear everything down
#
# - Target account = AWS_PROFILE (nothing hardcoded).
# - Region is the SOURCE OF TRUTH from <env>.tfvars.
# - <env> selects <env>.tfvars AND a verified Terraform workspace.
cd "$(dirname "$0")" || exit 1
. ./lib.sh

# Local tfvars + Terraform state hold plaintext control-plane secrets. Restrict
# to owner-only so files Terraform (re)writes this run are not group/world-readable. (#25)
umask 077

ENV="${1:-}"; ACTION="${2:-}"
[ -n "$ENV" ] && [ -n "$ACTION" ] || {
  echo "usage: AWS_PROFILE=<profile> ./deploy.sh <env> <preflight|plan|apply|install|destroy>"; exit 1; }

# Secure the secret-bearing files (tfvars + all local state incl. backups) to
# owner-only, FAIL CLOSED if any can't be secured. This MUST run BEFORE anything
# that can fail (tg_init does AWS reads + terraform init + workspace select),
# and via an EXIT trap, so a fresh install with pre-existing loose files is never
# exposed during init and the trap fires even if init fails. TFVARS is derived
# here from $ENV (same rule as lib.sh) so we don't depend on tg_init. (#25)
TFVARS="${ENV}.tfvars"
secure_secret_files() {
  local f mode bad=0
  local files=("$TFVARS")
  if [ -d terraform.tfstate.d ]; then
    while IFS= read -r f; do files+=("$f"); done \
      < <(find terraform.tfstate.d -type f -name 'terraform.tfstate*' 2>/dev/null)
  fi
  for f in "${files[@]}"; do
    [ -e "$f" ] || continue
    chmod 600 "$f" || { echo "ERROR(#25): cannot chmod 600 $f"; bad=1; continue; }
    mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)"
    case "$mode" in *00) ;; *) echo "ERROR(#25): $f not owner-only after chmod (mode $mode)"; bad=1 ;; esac
  done
  return "$bad"
}
# EXIT trap: re-secure on ANY exit (incl. init/terraform failure). Preserve the
# original exit status; surface (do not fully silence) a cleanup failure. (#25)
# shellcheck disable=SC2154  # rc is assigned as the first statement of the trap body
trap 'rc=$?; secure_secret_files || echo "WARNING(#25): could not secure all secret files on exit"; exit $rc' EXIT
# Up-front gate BEFORE tg_init: fail closed if existing files cannot be secured.
secure_secret_files || { echo "Refusing to proceed: secret files are not owner-only."; exit 1; }

# preflight runs before workspace/init so it can catch problems early. (Perms are
# already secured above before this hands off.)
if [ "$ACTION" = "preflight" ]; then exec ./preflight.sh "$ENV"; fi

tg_init "$ENV"

do_apply() {
  "$TF" apply -input=false -auto-approve -var-file="$TFVARS"
  CF="$("$TF" output -raw cloudfront_enabled 2>/dev/null || echo false)"
  if [ "$CF" = "true" ]; then
    echo "==> enforcing CloudFront origin lock (issue #5)"
    ./restrict-ingress.sh "$ENV"
    # #46: keep the ALB idle timeout >= the CloudFront origin read timeout so the
    # ALB isn't the new binding limit on long LLM streaming gaps. The upstream
    # module hardcodes ALB idle_timeout=120 and doesn't expose it, so reconcile it
    # here (same post-apply pattern as ingress). Non-fatal: a failure just leaves
    # the module default — log it, don't abort the install.
    # Read the CONFIGURED CloudFront timeout from the real output (#46). If the
    # output is missing/empty, SKIP the ALB change — never guess a stale constant
    # (a wrong value creates ALB↔CF drift + repeat-plan churn).
    CF_TO="$("$TF" output -raw cloudfront_origin_read_timeout 2>/dev/null || true)"
    ALB_DNS="$(tf_output alb_dns_name 2>/dev/null || true)"
    if [ -z "$CF_TO" ]; then
      echo "   NOTE(#46): cloudfront_origin_read_timeout output unavailable — leaving ALB idle timeout unchanged (no stale-constant guess)."
    elif [ -n "$ALB_DNS" ]; then
      ALB_ARN="$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='${ALB_DNS}'].LoadBalancerArn|[0]" --output text 2>/dev/null || true)"
      if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
        echo "==> reconciling ALB idle_timeout -> ${CF_TO}s (>= CloudFront origin read timeout) (#46)"
        aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$ALB_ARN" \
          --attributes "Key=idle_timeout.timeout_seconds,Value=${CF_TO}" >/dev/null 2>&1 \
          || echo "   WARNING(#46): could not set ALB idle_timeout to ${CF_TO}s (left module default); long streams may still drop at the ALB"
      fi
    fi
  else
    CIDRS="$("$TF" output -json alb_ingress_cidrs | python3 -c 'import json, sys; print(",".join(json.load(sys.stdin)))')"
    [ -n "$CIDRS" ] || { echo "ERROR: alb_ingress_cidrs output is empty"; exit 1; }
    echo "==> enforcing ALB ingress allowlist"
    ALLOW_CIDRS="$CIDRS" ./restrict-ingress.sh "$ENV"
  fi
  # Re-secure files Terraform may have (re)created this run; fail closed if not
  # owner-only. (The EXIT trap also covers failure paths.) (#25)
  secure_secret_files || { echo "ERROR(#25): could not secure secret files post-apply"; exit 1; }
  echo "==> outputs:"; "$TF" output
}

# Supported client versions the rendered handoff packages target. Codex model
# metadata is client-version-specific (#40), so the handoff records a version.
# These are FALLBACKS — write_handoff derives the ACTUAL installed version from the
# CLI when present so the metadata never advertises a stale version (#44).
SUPPORTED_CLAUDE_CODE_VERSION="2.1.214"
SUPPORTED_CODEX_VERSION="0.144.6"

# Is Codex enabled for this env? Reads the explicit enable_codex tfvars flag (#40.4).
codex_enabled() { [ "$(tfvars_get "$TFVARS" enable_codex)" = "true" ]; }

# Write NON-SECRET machine-readable installer handoff metadata (#40.7). Contains
# env name, gateway/admin URLs, registered client-facing model aliases, supported
# client versions, enabled client families, and SECRET REFERENCES only — never a
# master key, UI password, or developer key value.
write_handoff() { # $1 env  $2 gateway_url  $3 master_key_secret_arn
  local env="$1" gw="$2" mk_arn="$3" out="handoff.${1}.json" codex="false"
  codex_enabled && codex="true"
  # Client-facing model aliases from the SERVING gateway (ids only — not secrets).
  local aliases
  aliases="$(tg_curl "Authorization: Bearer" "$MK" -s -m 20 "$gw/v1/models" \
    | python3 -c "import sys,json; print(json.dumps([m['id'] for m in json.load(sys.stdin).get('data',[])]))" 2>/dev/null || echo '[]')"
  # Derive ACTUAL installed client versions when the CLI is present; else fall back
  # to the supported constant. Keeps handoff metadata truthful (#44).
  local claude_ver codex_ver
  claude_ver="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; claude_ver="${claude_ver:-$SUPPORTED_CLAUDE_CODE_VERSION}"
  codex_ver="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; codex_ver="${codex_ver:-$SUPPORTED_CODEX_VERSION}"
  ENV="$env" GW="$gw" MK_ARN="$mk_arn" CODEX="$codex" ALIASES="$aliases" \
  CLAUDE_VER="$claude_ver" CODEX_VER="$codex_ver" \
  python3 - > "$out" <<'PY'
import json, os
doc = {
    "schema": "tg-llmgateway/handoff@1",
    "environment": os.environ["ENV"],
    "gateway_url": os.environ["GW"],
    "admin_url": os.environ["GW"].rstrip("/") + "/ui",
    "client_facing_model_aliases": json.loads(os.environ["ALIASES"]),
    "enabled_clients": ["claude"] + (["codex"] if os.environ["CODEX"] == "true" else []),
    "supported_client_versions": {
        "claude_code": os.environ["CLAUDE_VER"],
        "codex": os.environ["CODEX_VER"],
    },
    # References ONLY — the admin/portal reads the value from Secrets Manager.
    "secret_references": {"master_key_secret_arn": os.environ["MK_ARN"]},
    "note": "Non-secret metadata for the admin/portal renderer. Contains NO key/password values.",
}
print(json.dumps(doc, indent=2))
PY
  chmod 600 "$out"   # metadata is non-secret, but keep it consistent with owner-only outputs
  echo "   wrote non-secret handoff metadata -> $(pwd)/$out"
}

case "$ACTION" in
  plan)    "$TF" plan -input=false -var-file="$TFVARS" ;;
  apply)   do_apply
           echo "==> NEXT: ./grant-bedrock.sh $ENV  then register models (see docs/installer.md)" ;;
  destroy) "$TF" destroy -input=false -auto-approve -var-file="$TFVARS" ;;
  install)
    # One-command install is FAIL-CLOSED (#40.1/#41): preflight runs automatically
    # before any apply, and EVERY required stage (apply, Bedrock grant, model
    # registration, model visibility, enabled-route verification) must succeed or
    # the installer exits non-zero. It never prints "Install complete" after a
    # swallowed failure.
    #
    # preflight validates tools/identity/tfvars/AZs/TLS/secrets AND (when
    # enable_codex=true) the Codex credential/refresher config. Run it FIRST, in a
    # subshell (it calls tg_init itself), and abort on any ERR.
    echo "==> [1/5] preflight"
    ( exec ./preflight.sh "$ENV" ) || { echo "ERROR(#40): preflight failed — fix the ERR items above; aborting install."; exit 1; }

    echo "==> [2/5] apply infrastructure"
    do_apply     # already fail-closed: `set -e` + explicit exits on ingress/perms

    echo "==> [3/5] granting Bedrock to the gateway task role"
    ./grant-bedrock.sh "$ENV" || { echo "ERROR(#40): grant-bedrock failed; aborting install."; exit 1; }

    # Codex on-by-default (#61): mint the FIRST short-term Bedrock API key and write
    # it into the Terraform-owned BEDROCK_API_KEY secret, so a fresh Codex-on install
    # needs no manual secret step. The refresher Lambda owns rotation from here. This
    # replicates the Lambda's algorithm exactly (SigV4-presign a CallWithBearerToken
    # POST, base64). Fail-closed: if we can't mint, abort rather than banner-success
    # over a broken Codex route. Skipped cleanly when Codex is disabled.
    if [ "$(tfvars_get "$TFVARS" enable_codex)" != "false" ]; then
      BAK_ARN="$(tf_output bedrock_api_key_secret_arn 2>/dev/null || true)"
      if [ -z "$BAK_ARN" ]; then
        echo "ERROR(#61): enable_codex is on but bedrock_api_key_secret_arn output is empty; aborting."; exit 1
      fi
      echo "==> [3b/5] minting initial Codex/Mantle Bedrock API key -> $BAK_ARN"
      BAK_TOKEN="$(REGION="$REGION" python3 - <<'PY' 2>/dev/null
import base64, os, boto3
from botocore.auth import SigV4QueryAuth
from botocore.awsrequest import AWSRequest
HOST="bedrock.amazonaws.com"; SERVICE="bedrock"; PREFIX="bedrock-api-key-"; VERSION="&Version=1"; TTL=43200
region=os.environ["REGION"]
creds=boto3.Session().get_credentials().get_frozen_credentials()
req=AWSRequest(method="POST", url=f"https://{HOST}/", headers={"host":HOST}, params={"Action":"CallWithBearerToken"})
SigV4QueryAuth(creds, SERVICE, region, expires=TTL).add_auth(req)
print(PREFIX+base64.b64encode((req.url.replace("https://","")+VERSION).encode()).decode())
PY
)"
      case "$BAK_TOKEN" in
        bedrock-api-key-*) : ;;
        *) echo "ERROR(#61): failed to mint the Bedrock API key (need bedrock perms + region Mantle access); aborting."; exit 1 ;;
      esac
      aws secretsmanager put-secret-value --secret-id "$BAK_ARN" --secret-string "$BAK_TOKEN" >/dev/null 2>&1 \
        || { echo "ERROR(#61): could not write the minted key to $BAK_ARN; aborting."; exit 1; }
      # Roll the gateway so it picks up the freshly-populated secret at task start.
      # Service name is <tenant>-litellm-<env>-gateway; fall back to a cluster lookup.
      CLUSTER="$(tf_output ecs_cluster 2>/dev/null || true)"
      if [ -n "$CLUSTER" ]; then
        TENANT="$(tfvars_get "$TFVARS" tenant)"
        GW_SVC="${TENANT:+${TENANT}-}litellm-${ENV}-gateway"
        aws ecs update-service --cluster "$CLUSTER" --service "$GW_SVC" --force-new-deployment >/dev/null 2>&1 \
          || { alt="$(aws ecs list-services --cluster "$CLUSTER" --query "serviceArns[?contains(@,'gateway')]|[0]" --output text 2>/dev/null || true)"
               [ -n "$alt" ] && [ "$alt" != "None" ] && aws ecs update-service --cluster "$CLUSTER" --service "$alt" --force-new-deployment >/dev/null 2>&1; } \
          || echo "   NOTE(#61): could not force a gateway redeploy; the refresher/next deploy will pick up the key."
      fi
      echo "   ok   minted + stored the initial Bedrock API key (refresher owns rotation)"
    fi

    # With CloudFront on, the ALB 403s direct traffic — reach the gateway via
    # the CloudFront URL. Otherwise use the ALB URL directly. These are REQUIRED
    # now: a missing URL/master key is a hard failure, not a "run it manually" note.
    GW_URL="$(tf_output cloudfront_url 2>/dev/null || true)"
    [ -n "$GW_URL" ] || GW_URL="$(tf_output alb_url)" || { echo "ERROR(#40): could not resolve gateway URL from outputs; aborting."; exit 1; }
    MK_ARN="$(tf_output master_key_secret_arn)" || { echo "ERROR(#40): master_key_secret_arn output missing; aborting."; exit 1; }
    MK="$(aws secretsmanager get-secret-value --secret-id "$MK_ARN" --query SecretString --output text 2>/dev/null || true)"
    [ -n "$MK" ] || { echo "ERROR(#40): could not read master key from $MK_ARN; aborting."; exit 1; }

    echo "==> [4/5] registering Bedrock + Mantle models via $GW_URL"
    # Wait for the gateway to become live before registering. A /health/liveliness
    # 200 is NOT sufficient on a fresh deploy (#52): the gateway app answers while
    # the ALB target group / CloudFront origin is not yet routing authenticated
    # POSTs, so /model/new gets edge 502s and burns its window. Gate on a real
    # AUTHENTICATED round-trip through the SAME path registration uses (an admin
    # GET /v1/models via the master key returning 200), not just liveliness.
    live=0
    for _ in $(seq 1 20); do curl -sf -m 15 "$GW_URL/health/liveliness" >/dev/null 2>&1 && { live=1; break; }; sleep 15; done
    [ "$live" = 1 ] || { echo "ERROR(#40): gateway did not become healthy at $GW_URL; aborting."; exit 1; }
    routed=0
    for _ in $(seq 1 20); do
      rc="$(tg_curl "Authorization: Bearer" "$MK" -s -o /dev/null -w '%{http_code}' -m 15 "$GW_URL/v1/models" 2>/dev/null || echo 000)"
      [ "$rc" = "200" ] && { routed=1; break; }
      echo "   waiting for authenticated routing through the gateway (got $rc)…"; sleep 15
    done
    [ "$routed" = 1 ] || { echo "ERROR(#52): gateway healthy but authenticated /v1/models did not route (edge 5xx); origin/target-group not ready; aborting."; exit 1; }
    # Model registration MUST succeed — no swallowed failure. (#40.2)
    ENV="$ENV" REGION="$REGION" LITELLM_URL="$GW_URL" LITELLM_MASTER_KEY="$MK" ./register-models.sh \
      || { echo "ERROR(#40): model registration failed — read its WARNING lines; aborting install (model set incomplete)."; exit 1; }
    # Model VISIBILITY gate: registration API success is not enough — the serving
    # gateway must list the COMPLETE persisted set, not merely ≥1 (#53 R2 / #62). A
    # partial snapshot (e.g. 40/73 mid-rollout) previously passed and then failed
    # Codex verification. register-models.sh already enforces this and fails non-zero
    # on an incomplete set; keep an independent completeness gate here so `install`
    # never banners success over a partial model set.
    vis_count=0; persisted=0
    for _ in $(seq 1 60); do          # ~5min bounded (covers a post-mint gateway redeploy)
      persisted="$(tg_curl "Authorization: Bearer" "$MK" -s -m 20 "$GW_URL/model/info" \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo 0)"
      vis_count="$(tg_curl "Authorization: Bearer" "$MK" -s -m 20 "$GW_URL/v1/models" \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo 0)"
      [ "${persisted:-0}" -gt 0 ] && [ "${vis_count:-0}" -ge "${persisted:-0}" ] && break
      sleep 5
    done
    { [ "${persisted:-0}" -gt 0 ] && [ "${vis_count:-0}" -ge "${persisted:-0}" ]; } \
      || { echo "ERROR(#40): gateway serves ${vis_count}/${persisted} models after registration + bounded wait — incomplete set (Codex may be missing); see store_model_in_db (#13); aborting."; exit 1; }
    echo "   ok   all $vis_count models visible on the serving gateway (complete)"

    echo "==> [5/5] verifying enabled routes"
    # Enabled-route verification is REQUIRED: verify.sh is fail-closed for Claude
    # (Messages). For Codex (Responses), a credential/model/region-not-ready state
    # is a loud WARNING (Claude still passes); only a configured-but-erroring Codex
    # route fails the install. (#40.3/#72)
    ./verify.sh "$ENV" || { echo "ERROR(#40): route verification failed; aborting install."; exit 1; }

    # Non-secret machine-readable handoff metadata for the admin/portal renderer (#40.7).
    write_handoff "$ENV" "$GW_URL" "$MK_ARN"

    echo ""
    echo "======================================================================"
    echo " Install complete — all required stages passed."
    echo "   Gateway : $GW_URL"
    echo "   Admin UI: $GW_URL/ui   (user: admin, password: your ui_password)"
    echo "   Master key: Secrets Manager ($MK_ARN)"
    echo "   Handoff  : $(pwd)/handoff.${ENV}.json  (non-secret metadata for the admin)"
    echo "======================================================================" ;;
  *) echo "unknown action: $ACTION (use preflight|plan|apply|install|destroy)"; exit 1 ;;
esac
