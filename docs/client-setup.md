# Use it — Claude Code & Codex CLI (developer guide)

**You do not configure anything by hand.** Your administrator gives you a complete,
environment-named configuration **package** (rendered per virtual key). Your entire
job is: paste it, source your shell profile, and run the launcher.

You never handle AWS credentials, never call `curl`, never discover models, never
write TOML, and never generate a catalog — the admin's rendered package already
contains the exact gateway URL, your key, your allowed models, and (for Codex) the
version-matched model catalog. If something is missing from the package, that is an
admin/portal issue, not something you patch locally.

---

## What the admin gives you

A named package for your environment (e.g. `prod`), delivered through your
organization's approved secure channel (internal portal or secure email — never a
public repo, never chat history). It looks like one of the two below and contains
**actual values**, already filled in. Executable snippets in the delivered package
contain no angle placeholders — you paste them verbatim.

---

## Claude Code — paste, source, launch

Your Claude package creates an **isolated** config dir (so it can't collide with
any other Claude Code setup on your machine) and an environment launcher. After the
admin process delivers it, the developer experience is only:

```bash
# 1. Paste the Claude package your admin gave you (creates the isolated config
#    + the launcher `claude-lg-prod` (named for your env)). Then:
source ~/.bash_profile
claude-lg-prod
```

The package (rendered for you by the admin — shown here as a template with
`$VARIABLES` only so you can see the shape; your copy has real values) does this:

```bash
# --- template shape (admin renders real values) ---
export LG_ENV="$ENV"                                   # e.g. prod
mkdir -p "$HOME/.claude-lg-$LG_ENV" && chmod 700 "$HOME/.claude-lg-$LG_ENV"
umask 077
cat > "$HOME/.claude-lg-$LG_ENV/settings.json" <<JSON
{
  "env": {
    "ANTHROPIC_BASE_URL": "$GATEWAY_URL",
    "ANTHROPIC_AUTH_TOKEN": "$VIRTUAL_KEY",
    "ANTHROPIC_MODEL": "$PRIMARY_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL": "$FAST_MODEL"
  },
  "permissions": { "defaultMode": "$PERMISSION_MODE" }
}
JSON
chmod 600 "$HOME/.claude-lg-$LG_ENV/settings.json"
# environment launcher: isolated CLAUDE_CONFIG_DIR so envs never cross-contaminate
cat >> "$HOME/.bash_profile" <<PROFILE
claude-lg-$LG_ENV() { CLAUDE_CONFIG_DIR="\$HOME/.claude-lg-$LG_ENV" claude "\$@"; }
PROFILE
```

- Uses `ANTHROPIC_AUTH_TOKEN` (the gateway virtual key), **not** `ANTHROPIC_API_KEY`.
- `CLAUDE_CONFIG_DIR` is isolated per environment, so switching environments starts
  a **fresh session** and never inherits another env's key.
- The key file is written owner-only (`chmod 600`). Don't commit it or echo it.

### Before you launch: managed-settings check (#39)

On a host with an enterprise **managed** Claude Code policy (a
`managed-settings.json` that pins a login method), Claude Code refuses token auth
and exits before inference — and `CLAUDE_CONFIG_DIR` **cannot** override it. Run
the check first (shipped in `deploy/`, or inline below):

```bash
# Exits 3 and prints the path + remediation if a managed policy is present.
./deploy/check-claude-managed-settings.sh || echo "-> use the container launch below"
```

Inline equivalent if you only have the package:

```bash
for p in /etc/claude-code/managed-settings.json \
         "/Library/Application Support/ClaudeCode/managed-settings.json" \
         "$PROGRAMDATA/ClaudeCode/managed-settings.json"; do
  [ -f "$p" ] && echo "MANAGED SETTINGS PRESENT: $p"
done
```

> **A working `/v1/messages` curl does NOT prove Claude Code works.** The gateway
> route can be healthy while the Claude Code **CLI** still refuses to launch under
> a managed policy. Qualify the actual CLI (`claude-lg-$ENV`), not just a curl —
> a blocked/untested CLI path is a failure, not a pass.

If a managed-settings file is present, token-auth mode and the forced managed-login
mode **cannot both be active in the same Claude Code process**. Use the
**container alternative** below (it does not alter your host's enterprise settings),
or ask IT for a reversible exception. Do not edit `/etc/claude-code/managed-settings.json`.

### Container alternative (works on a managed host)

Run Claude Code in a container that has none of your host's managed settings:

```bash
# The admin package exported LG_CLAUDE_VERSION (the pinned supported version).
# Pass it INTO the container explicitly — Docker does not inherit host vars (#48) —
# and pin the npm install to it so the container runs the qualified version.
docker run --rm -it \
  -e CLAUDE_CONFIG_DIR=/cfg \
  -e CLAUDE_CODE_VERSION="$LG_CLAUDE_VERSION" \
  -v "$HOME/.claude-lg-$LG_ENV:/cfg:ro" \
  -w /work -v "$PWD:/work" \
  node:22 bash -lc 'npm i -g @anthropic-ai/claude-code@"$CLAUDE_CODE_VERSION" && claude --version && claude'
```

This is the documented path for enterprise-managed hosts; it does not touch
`/etc/claude-code/managed-settings.json`.

---

## Codex CLI — paste, source, launch

Your Codex package writes an owner-only key file, a **named profile**
(`~/.codex/<env>.config.toml`) with the exact canonical default model and a
**complete, version-matched model catalog** (the admin generated it for the
supported Codex version — you do not run `make-codex-catalog.sh`), and a launcher:

```bash
# 1. Paste the Codex package your admin gave you (writes the key file, the named
#    profile + catalog, and the launcher `codex-lg-prod` (named for your env)). Then:
source ~/.bash_profile
codex-lg-prod
```

Template shape (admin renders real values; `$VARIABLES` shown only to illustrate):

```toml
# ~/.codex/$ENV.config.toml  (rendered by the admin)
model = "$CANONICAL_MODEL"                # exact canonical ID, e.g. openai.gpt-5.6-sol
model_provider = "litellm-gw"
model_catalog_json = "$HOME/.codex/$ENV-models.json"   # complete catalog, admin-generated
web_search = "disabled"                   # native web search not supported via the gateway

[model_providers.litellm-gw]
name = "LiteLLM Gateway"
base_url = "$GATEWAY_URL/v1"
env_key = "LITELLM_KEY"
wire_api = "responses"                    # Codex uses the OpenAI Responses route
```

The launcher exports your key and selects the named profile, and starts a **fresh
session** so environments never resume across providers/keys:

```bash
# rendered launcher shape
codex-lg-$ENV() { LITELLM_KEY="$VIRTUAL_KEY" codex --profile "$ENV" "$@"; }
```

- `wire_api = "responses"` — Codex talks to the gateway's `/v1/responses`.
- Your key must allow the **exact** canonical model ID in the profile; the admin
  set both to match. `codex /model` lists every compatible model your key allows
  (and none it doesn't).
- Start a fresh session when switching environments — don't resume across envs.

---

## If you're over budget

A `Budget has been exceeded!` response means you've hit your cap — working as
intended. Contact your admin. (Enforcement is eventually consistent — a raised cap
takes a short time to take effect.)

---

## Note for administrators

The packages above are **rendered** by the admin handoff renderer, not written by
developers. See [admin.md](admin.md) → "Render a developer package".
