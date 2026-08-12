#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&B||C idiom is intentional; reporters never fail
# Lock the ALB security group down so it is not open to the world.
#
# Two modes (deploy.sh picks based on the cloudfront_enabled terraform output):
#
#   CIDR allowlist (default, issue #4):
#     AWS_PROFILE=<p> ALLOW_CIDRS="1.2.3.4/32,5.6.7.8/32" ./restrict-ingress.sh <env>
#   CloudFront origin lock (issue #5, when enable_cloudfront=true):
#     AWS_PROFILE=<p> ./restrict-ingress.sh <env>
#     -> SG ingress restricted to CloudFront's managed origin-facing prefix list,
#        and the ALB listener 403s any request missing the X-Origin-Verify secret.
#
# The upstream module hardcodes public rules, so deploy.sh runs this immediately
# after every apply. Direct `terraform apply` is unsupported (issue #4) because it
# bypasses this reconciliation and restores the public rules.
cd "$(dirname "$0")" || exit
. ./lib.sh
tg_init "${1:-}"

CF_ENABLED="$(tf_output cloudfront_enabled 2>/dev/null || echo false)"

# Resolve the ALB deterministically from Terraform state (its DNS output), then
# map DNS -> LoadBalancerArn -> SG. Shared by both modes.
resolve_alb() {
  ALB_DNS="$(tf_output alb_dns_name 2>/dev/null || true)"
  if [ -z "$ALB_DNS" ]; then
    local url; url="$(tf_output alb_url)"; ALB_DNS="${url#*://}"; ALB_DNS="${ALB_DNS%%/*}"
  fi
  [ -n "$ALB_DNS" ] || { echo "ERROR: could not resolve ALB DNS from Terraform outputs"; exit 1; }
  ALB_ARN="$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?DNSName=='${ALB_DNS}'].LoadBalancerArn|[0]" --output text)"
  [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ] || { echo "ERROR: no ALB found with DNS $ALB_DNS"; exit 1; }
  SG="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].SecurityGroups[0]' --output text)"
  [ -n "$SG" ] && [ "$SG" != "None" ] || { echo "ERROR: could not resolve ALB security group"; exit 1; }
  echo "==> ALB=$ALB_DNS  SG=$SG"
}

if [ "$CF_ENABLED" = "true" ]; then
  echo "==> CloudFront origin-lock mode (issue #5)"
  resolve_alb

  # The AWS-managed prefix list of CloudFront's origin-facing IP ranges.
  PL_ID="$(aws ec2 describe-managed-prefix-lists \
    --filters "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing" \
    --query 'PrefixLists[0].PrefixListId' --output text)"
  [ -n "$PL_ID" ] && [ "$PL_ID" != "None" ] || {
    echo "ERROR: could not resolve CloudFront origin-facing managed prefix list"; exit 1; }
  echo "   CloudFront prefix list=$PL_ID"

  # CloudFront talks to the origin over HTTP (cloudfront.tf uses http-only), so
  # the ALB only needs port 80 open to the prefix list. IMPORTANT: a managed
  # prefix-list rule counts as its FULL entry-count against the "rules per SG"
  # quota (the CloudFront list is ~45 entries, quota default 60), so opening a
  # second port would blow the limit. One port only.
  CF_PORT=80

  # Revoke FIRST, then add: revoke every non-prefix-list ingress rule on 80/443
  # (the module's 0.0.0.0/0 and any stale CIDR allowlist) BEFORE authorizing the
  # prefix-list rule. This closes world access immediately and frees quota so the
  # prefix-list rule fits. (Briefly no ingress — acceptable; the alternative
  # exceeds the rule limit.)
  while IFS=$'\t' read -r RULE_ID CIDR RULE_PL PORT; do
    case "$PORT" in 80|443) ;; *) continue ;; esac
    [ "$RULE_PL" = "$PL_ID" ] && [ "$PORT" = "$CF_PORT" ] && continue
    aws ec2 revoke-security-group-ingress --group-id "$SG" \
      --security-group-rule-ids "$RULE_ID" >/dev/null
    echo "   revoked ${CIDR:-${RULE_PL:-non-CIDR source}}:$PORT"
  done < <(aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=$SG" \
    --query 'SecurityGroupRules[?IsEgress==`false` && IpProtocol==`tcp`].[SecurityGroupRuleId,CidrIpv4,PrefixListId,FromPort]' \
    --output text)

  # Now allow the CloudFront prefix list on the origin port (idempotent).
  PRESENT="$(aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=$SG" \
    --query "length(SecurityGroupRules[?IsEgress==\`false\` && IpProtocol==\`tcp\` && FromPort==\`$CF_PORT\` && ToPort==\`$CF_PORT\` && PrefixListId==\`$PL_ID\`])" \
    --output text)"
  if [ "$PRESENT" -gt 0 ]; then
    echo "   prefix-list $PL_ID:$CF_PORT already present (ok)"
  else
    aws ec2 authorize-security-group-ingress --group-id "$SG" \
      --ip-permissions "IpProtocol=tcp,FromPort=$CF_PORT,ToPort=$CF_PORT,PrefixListIds=[{PrefixListId=$PL_ID}]" >/dev/null
    echo "   allowed prefix-list $PL_ID:$CF_PORT"
  fi

  # This script OWNS the WAF→ALB association (see the note in cloudfront.tf): a
  # Terraform data-source binding can't be both first-install-safe and stable, so
  # we bind it here after apply, when the ALB always exists. Idempotent: associate
  # only if not already associated. We do NOT touch the module's listener/routing
  # rules (a forward-all header rule would shadow /v1 routing). (#12)
  WACL_ARN="$(tf_output origin_lock_web_acl_arn 2>/dev/null || true)"
  if [ -z "$WACL_ARN" ] || [ "$WACL_ARN" = "None" ]; then
    WACL_ARN="$(aws wafv2 list-web-acls --scope REGIONAL \
      --query "WebACLs[?ends_with(Name, 'origin-lock')].ARN | [0]" --output text 2>/dev/null || true)"
  fi
  if [ -n "$WACL_ARN" ] && [ "$WACL_ARN" != "None" ]; then
    ASSOC="$(aws wafv2 list-resources-for-web-acl --web-acl-arn "$WACL_ARN" \
      --resource-type APPLICATION_LOAD_BALANCER --query "length(ResourceArns[?@=='$ALB_ARN'])" --output text 2>/dev/null || echo 0)"
    if [ "${ASSOC:-0}" -gt 0 ]; then
      echo "   WAF origin-lock already associated (ok)"
    else
      aws wafv2 associate-web-acl --web-acl-arn "$WACL_ARN" --resource-arn "$ALB_ARN" >/dev/null 2>&1 \
        && echo "   associated WAF origin-lock to the ALB" \
        || { echo "ERROR: could not associate WAF origin-lock to the ALB — origin is not fully locked"; exit 1; }
    fi
  else
    echo "ERROR: no origin-lock WebACL found — is enable_cloudfront applied? Origin is not WAF-protected"; exit 1
  fi

  echo "==> current ALB SG ingress:"
  aws ec2 describe-security-groups --group-ids "$SG" \
    --query 'SecurityGroups[0].IpPermissions[].{from:FromPort,cidrs:IpRanges[].CidrIp,pls:PrefixListIds[].PrefixListId}' --output json
  echo "WARNING: use deploy.sh for applies; direct 'terraform apply' restores public upstream rules."
  exit 0
fi

: "${ALLOW_CIDRS:?set ALLOW_CIDRS=comma,separated,cidrs (e.g. 1.2.3.4/32,5.6.7.8/32)}"
python3 - "$ALLOW_CIDRS" <<'PY'
import ipaddress
import sys

cidrs = [value.strip() for value in sys.argv[1].split(",") if value.strip()]
if not cidrs:
    raise SystemExit("ERROR: ALLOW_CIDRS must contain at least one CIDR")
for value in cidrs:
    network = ipaddress.ip_network(value, strict=False)
    if network.version != 4 or network.prefixlen == 0:
        raise SystemExit(f"ERROR: prohibited ALB ingress CIDR: {value}")
PY

resolve_alb

# Authorize the allowlist before revoking other access to avoid an ingress gap.
IFS=',' read -ra CIDRS <<< "$ALLOW_CIDRS"
for CIDR in "${CIDRS[@]}"; do
  [ -n "$CIDR" ] || continue
  for PORT in 80 443; do
    PRESENT="$(aws ec2 describe-security-group-rules \
      --filters "Name=group-id,Values=$SG" \
      --query "length(SecurityGroupRules[?IsEgress==\`false\` && IpProtocol==\`tcp\` && FromPort==\`$PORT\` && ToPort==\`$PORT\` && CidrIpv4==\`$CIDR\`])" \
      --output text)"
    if [ "$PRESENT" -gt 0 ]; then
      echo "   $CIDR:$PORT already present (ok)"
    else
      aws ec2 authorize-security-group-ingress --group-id "$SG" \
        --protocol tcp --port "$PORT" --cidr "$CIDR" >/dev/null
      echo "   allowed $CIDR:$PORT"
    fi
  done
done

cidr_is_allowed() {
  local candidate="$1" allowed
  for allowed in "${CIDRS[@]}"; do
    [ "$candidate" = "$allowed" ] && return 0
  done
  return 1
}

# Remove every stale IPv4 or security-group source on the public listener ports.
while IFS=$'\t' read -r RULE_ID CIDR PORT; do
  case "$PORT" in 80|443) ;; *) continue ;; esac
  if [ "$CIDR" = "None" ] || ! cidr_is_allowed "$CIDR"; then
    aws ec2 revoke-security-group-ingress --group-id "$SG" \
      --security-group-rule-ids "$RULE_ID" >/dev/null
    echo "   revoked ${CIDR:-non-CIDR source}:$PORT"
  fi
done < <(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$SG" \
  --query 'SecurityGroupRules[?IsEgress==`false` && IpProtocol==`tcp`].[SecurityGroupRuleId,CidrIpv4,FromPort]' \
  --output text)

echo "==> current ALB SG ingress:"
aws ec2 describe-security-groups --group-ids "$SG" \
  --query 'SecurityGroups[0].IpPermissions[].{from:FromPort,cidrs:IpRanges[].CidrIp}' --output json
echo "WARNING: use deploy.sh for applies; direct 'terraform apply' restores public upstream rules."
