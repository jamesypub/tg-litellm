#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&B||C idiom is intentional; reporters never fail
# Attach Bedrock invoke permissions to the LiteLLM gateway ECS task role.
# The BerriAI module does NOT grant Bedrock by default — this closes that gap.
#
#   AWS_PROFILE=<profile> ./grant-bedrock.sh <env>
#
# Default: scoped to this account/region's foundation-model/* and
# inference-profile/* ARNs (not Resource="*"). Set BEDROCK_RESOURCES
# (comma-separated ARNs) to narrow further to specific models. (#18)
cd "$(dirname "$0")" || exit 1
. ./lib.sh
tg_init "${1:-}"

CLUSTER="$(tf_output ecs_cluster)"
SVC_ARN="$(aws ecs list-services --cluster "$CLUSTER" --query 'serviceArns[?contains(@,`gateway`)]|[0]' --output text)"
[ -n "$SVC_ARN" ] && [ "$SVC_ARN" != "None" ] || { echo "ERROR: no gateway service found in cluster $CLUSTER"; exit 1; }
TASKDEF="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SVC_ARN" --query 'services[0].taskDefinition' --output text)"
ROLE_ARN="$(aws ecs describe-task-definition --task-definition "$TASKDEF" --query 'taskDefinition.taskRoleArn' --output text)"
ROLE_NAME="${ROLE_ARN##*/}"
[ -n "$ROLE_NAME" ] && [ "$ROLE_NAME" != "None" ] || { echo "ERROR: could not resolve gateway task role"; exit 1; }
echo "==> gateway task role: $ROLE_NAME"

# Least-privilege: scope Bedrock invoke to foundation-models + inference-profiles
# in this account/region, rather than Resource:"*". (#18) Override BEDROCK_RESOURCES
# (comma-separated ARNs) to narrow further to specific models.
ACCT="$(aws sts get-caller-identity --query Account --output text)"
if [ -n "${BEDROCK_RESOURCES:-}" ]; then
  IFS=',' read -ra RES <<< "$BEDROCK_RESOURCES"
else
  RES=(
    "arn:aws:bedrock:${REGION}::foundation-model/*"
    "arn:aws:bedrock:${REGION}:${ACCT}:inference-profile/*"
    "arn:aws:bedrock:*::foundation-model/*"                       # global/CRIS cross-region profiles
    "arn:aws:bedrock:${REGION}:${ACCT}:application-inference-profile/*"
  )
fi
RES_JSON="$(printf '"%s",' "${RES[@]}" | sed 's/,$//')"

POLICY_FILE="$(mktemp)"
trap 'rm -f "$POLICY_FILE"' EXIT
cat > "$POLICY_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:Converse",
      "bedrock:ConverseStream"
    ],
    "Resource": [${RES_JSON}]
  }]
}
JSON

aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "${ENV}-litellm-bedrock-invoke" \
  --policy-document "file://$POLICY_FILE"
echo "==> attached ${ENV}-litellm-bedrock-invoke to $ROLE_NAME (scoped to Bedrock model/profile ARNs)"
# NOTE (#18): the vendored LiteLLM module gives the gateway AND management backend
# the SAME ECS task role, so this policy is visible to both. Separating them would
# require patching the upstream module (it does not expose per-service task roles).
# Scoping Resource above limits the blast radius; the shared-role split is tracked
# upstream. Mantle/Codex uses the bearer key, not this role.
