#!/usr/bin/env bash
# Cron wrapper for the multi-account Mantle token refresher (#128/#129).
# Mints a Bedrock bearer token for a secondary AWS account and writes it to a
# Secrets Manager secret in the gateway account.
#
# Config is INJECTED, never baked in. Provide it either way:
#   1. a config file next to this script: refresh-mantle-account.env
#      (copy refresh-mantle-account.env.sample -> refresh-mantle-account.env and fill in)
#   2. the same variables already exported in the environment.
# Precedence: THE ENVIRONMENT WINS — an exported var is authoritative and the
# file only fills what is unset.
#
# Required: REGION, SECRET_ARN, CRED_MODE, UPDATE_ECS
#   CRED_MODE = instance_role  -> host EC2 role supplies creds
#             = profile         -> also set AWS_PROFILE
#   UPDATE_ECS = false          -> write token only (secondary account — runs first)
#              = true           -> write token AND restart ECS (primary / last account)
#   ECS_CLUSTER, ECS_SERVICE    -> required only when UPDATE_ECS=true
#
# Cron: secondary account fires BEFORE the primary account refresher so all tokens
# are fresh before the single ECS restart. Stagger by ~3 minutes:
#   0 */6 * * *   $HOME/.tg-litellm/refresh-mantle-account.sh >> $HOME/.tg-litellm/refresh-demo0.log 2>&1
#   3 */6 * * *   $HOME/.tg-litellm/refresh-codex-key.sh      >> $HOME/.tg-litellm/refresh.log 2>&1
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_VARS="REGION SECRET_ARN LITELLM_URL LITELLM_MASTER_KEY BEDROCK_API_KEY_ENV CRED_MODE UPDATE_ECS ECS_CLUSTER ECS_SERVICE AWS_PROFILE"

if [ -f "$here/refresh-mantle-account.env" ]; then
  __preset=""
  for v in $CFG_VARS; do
    if eval "[ \"\${$v+x}\" = x ]"; then eval "__val_$v=\$$v"; __preset="$__preset $v"; fi
  done
  # shellcheck disable=SC1091
  . "$here/refresh-mantle-account.env"
  for v in $__preset; do eval "$v=\$__val_$v"; done
fi

die() { echo "refresh-mantle-account: $*" >&2; exit 1; }

for v in REGION SECRET_ARN LITELLM_URL LITELLM_MASTER_KEY BEDROCK_API_KEY_ENV CRED_MODE UPDATE_ECS; do
  [ -n "${!v:-}" ] || die "missing required config: $v"
done

# Normalize UPDATE_ECS to lowercase so TRUE/True/true all work; Python already
# lowercases it but the shell case-match below must agree.
UPDATE_ECS="$(echo "${UPDATE_ECS:-false}" | tr '[:upper:]' '[:lower:]')"
if [ "$UPDATE_ECS" = "true" ]; then
  for v in ECS_CLUSTER ECS_SERVICE; do
    [ -n "${!v:-}" ] || die "UPDATE_ECS=true requires $v"
  done
elif [ "$UPDATE_ECS" != "false" ]; then
  die "UPDATE_ECS must be true or false (got '${UPDATE_ECS}')"
fi

case "$CRED_MODE" in
  instance_role)
    unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN ;;
  profile)
    [ -n "${AWS_PROFILE:-}" ] || die "CRED_MODE=profile requires AWS_PROFILE"
    # Unset static-key env vars so boto3 resolves the named profile rather than
    # falling back to any inherited AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
    # AWS_SESSION_TOKEN, which take precedence over the profile in the credential
    # chain and would mint a token for the wrong account.
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    export AWS_PROFILE ;;
  *) die "CRED_MODE must be instance_role or profile (got '$CRED_MODE')" ;;
esac

export REGION SECRET_ARN LITELLM_URL LITELLM_MASTER_KEY BEDROCK_API_KEY_ENV UPDATE_ECS
[ "${UPDATE_ECS}" = "true" ] && export ECS_CLUSTER ECS_SERVICE
exec python3 "$here/refresh-mantle-account.py"
