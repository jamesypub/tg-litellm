#!/usr/bin/env bash
# Detect an enterprise Claude Code MANAGED-settings policy that conflicts with
# LiteLLM token auth (#39). Claude Code refuses `ANTHROPIC_AUTH_TOKEN` when a host
# managed-settings.json pins a login/gateway method, and CLAUDE_CONFIG_DIR CANNOT
# override it. This is a developer-host check, safe to ship in a rendered package.
#
#   ./check-claude-managed-settings.sh
#
# Exit 0 = no managed settings (token auth OK on this host).
# Exit 3 = managed settings present -> use the container alternative
#          (docs/client-setup.md) or ask IT for a reversible exception. Do NOT
#          edit the managed-settings file.
set -uo pipefail

# Standard managed-settings locations per OS (Linux / macOS / Windows).
CANDIDATES=(
  "/etc/claude-code/managed-settings.json"
  "/Library/Application Support/ClaudeCode/managed-settings.json"
  "${PROGRAMDATA:-/c/ProgramData}/ClaudeCode/managed-settings.json"
)

found=""
for p in "${CANDIDATES[@]}"; do
  [ -f "$p" ] && found="$p" && break
done

if [ -n "$found" ]; then
  cat >&2 <<MSG
MANAGED SETTINGS PRESENT: $found

Claude Code will refuse LiteLLM token auth (ANTHROPIC_AUTH_TOKEN) in the same
process as a forced managed-login policy, and CLAUDE_CONFIG_DIR cannot override
this file. Remediation (pick one):
  1. Use the container launch in docs/client-setup.md (does NOT alter host settings).
  2. Ask IT for a reversible managed-settings exception for this host.
Do not edit $found yourself.
MSG
  exit 3
fi

echo "ok: no Claude Code managed-settings policy found — token auth can be used on this host."
exit 0
