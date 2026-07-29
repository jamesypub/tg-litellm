#!/usr/bin/env bash
# Canonical cron wrapper for the no-Lambda Codex key refresher (#84). Sets a
# fail-closed environment, resolves credentials WITHOUT assuming an interactive
# AWS_PROFILE (cron does not inherit it), then execs refresh-codex-key.py.
#
# Config is INJECTED, never baked in (this is a shared repo file, not a
# per-customer render). Provide it either way:
#   1. a config file next to this script: refresh-codex-key.env
#      (copy refresh-codex-key.env.sample -> refresh-codex-key.env and fill in), or
#   2. the same variables already exported in the environment.
# Precedence when both are present: THE ENVIRONMENT WINS — an exported var is
# authoritative and the file only fills what is unset (so a cron/env override is
# never clobbered by a stale file).
# Required: REGION, SECRET_ARN, ECS_CLUSTER, ECS_SERVICE, CRED_MODE.
#   CRED_MODE = instance_role  -> host EC2 role supplies creds (export nothing)
#             = profile         -> export AWS_PROFILE (also required then)
#
# Cron line (re-mint every 6h; log to an OWNER-writable path, not /var/log):
#   0 */6 * * * $HOME/.tg-litellm/refresh-codex-key.sh >> $HOME/.tg-litellm/refresh.log 2>&1
set -euo pipefail
umask 077  # any file this process creates is owner-only

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Optional config file beside the script. Precedence: THE ENVIRONMENT WINS.
# An already-exported var is authoritative; the file only fills what is unset.
# (Sourcing unconditionally would let the file clobber an explicit override,
# reversing the documented contract — QA #84 round-6 finding.) Snapshot the
# known vars, source the file, then restore any that were preset.
CFG_VARS="REGION SECRET_ARN ECS_CLUSTER ECS_SERVICE CRED_MODE AWS_PROFILE"
if [ -f "$here/refresh-codex-key.env" ]; then
  # Snapshot which vars were SET in the environment — set-vs-unset, NOT
  # nonempty-vs-empty. An explicitly exported empty value is still an authoritative
  # override and must survive sourcing (so e.g. an empty AWS_PROFILE fails profile
  # mode CLOSED instead of the file silently refilling it) — QA #84 round-7.
  __preset=""
  for v in $CFG_VARS; do
    if eval "[ \"\${$v+x}\" = x ]"; then eval "__val_$v=\$$v"; __preset="$__preset $v"; fi
  done
  # shellcheck disable=SC1091
  . "$here/refresh-codex-key.env"
  for v in $__preset; do eval "$v=\$__val_$v"; done  # env override wins over the file
fi

die() { echo "refresh-codex-key: $*" >&2; exit 1; }

for v in REGION SECRET_ARN ECS_CLUSTER ECS_SERVICE CRED_MODE; do
  [ -n "${!v:-}" ] || die "missing required config: $v (set it in refresh-codex-key.env or the environment)"
done

case "$CRED_MODE" in
  # Host EC2 role supplies creds. Neutralize the FULL inherited-credential set, not
  # just AWS_PROFILE: boto3 resolves env static keys BEFORE the instance-metadata
  # role, so a leaked AWS_ACCESS_KEY_ID/SECRET/SESSION_TOKEN would silently mint
  # under the wrong identity. Mirrors the client launchers' AWS_* scrub — QA #84
  # round-7 finding: instance_role must be unambiguous.
  instance_role) unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN ;;
  profile) [ -n "${AWS_PROFILE:-}" ] || die "CRED_MODE=profile requires AWS_PROFILE"; export AWS_PROFILE ;;
  *) die "CRED_MODE must be instance_role or profile (got '$CRED_MODE')" ;;
esac

export REGION SECRET_ARN ECS_CLUSTER ECS_SERVICE
exec python3 "$here/refresh-codex-key.py"
