#!/usr/bin/env bash
# Shared helpers for the deploy scripts. Source this, don't execute it.
#
# Provides consistent, safe defaults for every helper:
#   - one Terraform binary resolution ($TF)
#   - AWS_PROFILE required (selects the account) — never a hardcoded default
#   - REGION is the SOURCE OF TRUTH from <env>.tfvars (not a divergent default)
#   - workspace select + verify before any state read
# Usage in a helper:
#   . "$(dirname "$0")/lib.sh"; tg_init "$ENV"
set -euo pipefail

# One Terraform binary everywhere.
TF="$(command -v terraform || echo "${HOME}/bin/terraform")"
export TF

# Read a top-level scalar string var from a tfvars file (region/tenant/env).
tfvars_get() { # $1 tfvars file  $2 key
  # Extract the RHS of `key = value`, tolerating an inline `# comment` and optional
  # quotes. HCL string values can't contain an unescaped '#', and our scalars
  # (bools/numbers/ARNs) never do, so stripping from the first '#' is safe here and
  # keeps `enable_codex = true   # note` from parsing as `true   # note`. (#61)
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" "$1" | head -1 \
    | sed 's/[[:space:]]*#.*$//; s/^"\(.*\)"$/\1/; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Initialize environment: requires AWS_PROFILE, derives REGION from tfvars,
# selects+verifies the Terraform workspace. Sets globals: ENV, TFVARS, REGION.
tg_init() { # $1 = env name
  ENV="${1:?usage: <env> required}"
  : "${AWS_PROFILE:?set AWS_PROFILE (selects the target AWS account)}"
  TFVARS="${ENV}.tfvars"
  [ -f "$TFVARS" ] || { echo "ERROR: $TFVARS not found (cp env.tfvars.example ${ENV}.tfvars)"; exit 1; }

  # REGION source of truth = tfvars; AWS_REGION must match if set.
  REGION="$(tfvars_get "$TFVARS" region)"
  [ -n "$REGION" ] || { echo "ERROR: 'region' not set in $TFVARS"; exit 1; }
  if [ -n "${AWS_REGION:-}" ] && [ "$AWS_REGION" != "$REGION" ]; then
    echo "ERROR: AWS_REGION=$AWS_REGION does not match $TFVARS region=$REGION"; exit 1
  fi
  export AWS_REGION="$REGION"

  local acct arn
  acct="$(aws sts get-caller-identity --query Account --output text)"
  arn="$(aws sts get-caller-identity --query Arn --output text)"
  echo "==> profile=$AWS_PROFILE account=$acct region=$REGION env=$ENV"
  echo "    identity=$arn"

  "$TF" init -input=false >/dev/null
  # select the requested workspace (create if needed), then VERIFY it.
  "$TF" workspace select "$ENV" >/dev/null 2>&1 || "$TF" workspace new "$ENV" >/dev/null
  local ws; ws="$("$TF" workspace show)"
  [ "$ws" = "$ENV" ] || { echo "ERROR: workspace is '$ws', expected '$ENV' — refusing to continue"; exit 1; }
  echo "    workspace=$ws (verified)"
}

# Secret-safe curl: pass the auth header via an owner-only --config file so the
# key never appears in the process table / argv (#50). HTTPS protects the network
# path, not the local `ps` output.
#   tg_curl <header-name> <secret-value> [curl args...]
# e.g.  tg_curl "Authorization: Bearer" "$MK" -s "$GW/v1/models"
#       tg_curl "x-api-key:" "$MK" -s "$GW/v1/messages" -d ...
# The header name includes everything before the secret (e.g. "Authorization: Bearer").
tg_curl() {
  local hname="$1" secret="$2"; shift 2
  local cfg; cfg="$(mktemp)"; chmod 600 "$cfg"
  printf 'header = "%s %s"\n' "$hname" "$secret" > "$cfg"
  # Capture curl's status WITHOUT letting `set -e` abort mid-function (which would
  # skip the rm and leave the owner-only config), then remove it unconditionally
  # and return the real status. Belt + suspenders with the RETURN trap so a forced
  # curl failure never leaves the secret-header file behind (#50).
  trap 'rm -f "$cfg"' RETURN
  local rc=0
  curl --config "$cfg" "$@" || rc=$?   # secret header via --config; never on argv
  rm -f "$cfg"
  return "$rc"
}

# Read a Terraform output, erroring if empty (state must be applied first).
tf_output() { # $1 = output name
  local v; v="$("$TF" output -raw "$1" 2>/dev/null || true)"
  [ -n "$v" ] || { echo "ERROR: terraform output '$1' is empty — has '$ENV' been applied?" >&2; return 1; }
  printf '%s' "$v"
}
