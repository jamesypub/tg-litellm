# Use it — Claude Code & Codex CLI (developer guide)

**You do not configure anything by hand.** Your administrator gives you a complete,
environment-named configuration **package** (rendered per virtual key). Your job is:
paste it, source your shell profile, run the launcher.

You never handle AWS credentials, call `curl`, discover models, or write TOML — the
rendered package already has the exact gateway URL, your key, your allowed models,
and (for Codex) the version-matched catalog. If something is missing, that's an
admin/portal issue, not something you patch locally.

> **Prefer a worked example?** `example/developer-setup/` (added in #89) has
> concrete, scrubbed, drop-in files for both tools — copy them, replace the gateway
> URL and your key, source, launch. Use it as the copy-paste reference and as
> something to diff against when a setup misbehaves. The samples below show the same
> shapes inline.

---

## Claude Code — paste, source, launch

Your Claude package creates an **isolated** config dir (so it can't collide with any
other Claude Code setup on your machine) plus an environment launcher:

```bash
# 1. Paste the Claude package your admin gave you.
# 2. Then:
source ~/.bash_profile
claude-lg-prod          # launcher named for your env
```

Sample of what the package writes (your copy has real values; replace the
gateway URL and your key if you're adapting it by hand):

```bash
mkdir -p "$HOME/.claude-lg-prod" && chmod 700 "$HOME/.claude-lg-prod"
umask 077
cat > "$HOME/.claude-lg-prod/settings.json" <<'JSON'
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://REPLACE_WITH_GATEWAY_URL",
    "ANTHROPIC_AUTH_TOKEN": "sk-<your-key>",
    "ANTHROPIC_MODEL": "claude-opus-4-8",
    "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4-5-20251001"
  }
}
JSON
chmod 600 "$HOME/.claude-lg-prod/settings.json"
# launcher: isolated CLAUDE_CONFIG_DIR + fail-closed scrub of conflicting vars
cat >> "$HOME/.bash_profile" <<'PROFILE'
claude-lg-prod() {
  for v in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX ANTHROPIC_API_KEY AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
    if [ -n "${!v:-}" ]; then echo "claude-lg-prod: conflicting provider var $v set; open a clean shell" >&2; return 3; fi
  done
  env -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u ANTHROPIC_API_KEY \
      CLAUDE_CONFIG_DIR="$HOME/.claude-lg-prod" claude "$@"
}
PROFILE
```

See `example/developer-setup/bash_profile_sample` for both launchers as a single
drop-in block.

- Uses `ANTHROPIC_AUTH_TOKEN` (the gateway virtual key), **not** `ANTHROPIC_API_KEY`.
- `CLAUDE_CONFIG_DIR` is isolated per environment — switching envs starts a fresh
  session and never inherits another env's key.
- The settings file is owner-only (`chmod 600`). Don't commit it or echo it.

---

## Codex CLI — paste, source, launch

Your Codex package writes an owner-only key file, a **named profile**
(`~/.codex/prod.config.toml`) with the exact canonical model and an admin-generated
model catalog, plus a launcher:

```bash
# 1. Paste the Codex package your admin gave you.
# 2. Then:
source ~/.bash_profile
codex-lg-prod           # launcher named for your env
```

Sample profile (your copy has real values; replace `REPLACE_WITH_GATEWAY_URL`):

```toml
# ~/.codex/prod.config.toml
model = "openai.gpt-5.6-sol"              # exact canonical ID
model_provider = "litellm-gw"
model_catalog_json = "$HOME/.codex/prod-models.json"   # admin-generated
web_search = "disabled"                   # native web search not supported via the gateway

[model_providers.litellm-gw]
name = "LiteLLM Gateway"
base_url = "https://REPLACE_WITH_GATEWAY_URL/v1"
env_key = "LITELLM_KEY"
wire_api = "responses"                    # Codex uses the OpenAI Responses route
```

The launcher sources your owner-only key file and selects the profile (it also
refuses to launch if a conflicting provider var is set, so it can't silently bypass
the gateway):

```bash
codex-lg-prod() {
  for v in OPENAI_API_KEY AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
    if [ -n "${!v:-}" ]; then echo "codex-lg-prod: conflicting var $v set; open a clean shell" >&2; return 3; fi
  done
  . "$HOME/.codex/prod.key"          # your key lives here (chmod 600), not inline
  env -u OPENAI_API_KEY codex --profile prod "$@"
}
```

- Your key must allow the **exact** canonical model ID in the profile; the admin set
  both to match. `codex /model` lists every compatible model your key allows.
- Start a fresh session when switching environments — don't resume across envs.

---

## If you're over budget

A `Budget has been exceeded!` response means you've hit your cap — working as
intended. Contact your admin. (Enforcement is eventually consistent — a raised cap
takes a short time to take effect.)

---

## Note for administrators

Developers get a virtual key from the admin plus the setup files in
[example/developer-setup](../example/developer-setup). See [admin.md](admin.md) →
"Give a developer access".
