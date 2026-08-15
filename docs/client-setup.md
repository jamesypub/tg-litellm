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

### Seeing the gateway's models in the `/model` picker

By default `/model` shows Claude Code's built-in aliases, **not** the set your
gateway registered. To include newly-added models, opt into one of these
(standard Claude Code settings — nothing changes until you set them):

- **Discovery (recommended)** — the whole registered catalog, self-updating:
  ```bash
  export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
  ```
  Export it in your shell or add it to `settings.json`'s `"env"` block; with
  `ANTHROPIC_BASE_URL` at the gateway, Claude Code fills `/model` from
  `/v1/models`. Future additions appear with no further edits.
- **`modelOverrides`** — pin the built-in rows to the **bare** aliases the
  gateway serves (a remap table, not new choices):
  ```json
  { "modelOverrides": { "claude-haiku-4-5-20251001": "claude-haiku-4-5" } }
  ```
- **`ANTHROPIC_CUSTOM_MODEL_OPTION`** — add exactly one new named row
  (`export ANTHROPIC_CUSTOM_MODEL_OPTION="<alias>"`); there is no array form.

**The picker lists what the gateway *serves*; you can still only *use* models
your key allows** — a disallowed pick returns a policy **403**. Pick the **bare**
alias (Claude Code rejects `us/…` / `global/…` slash names).

**FAQ — a built-in row fails but the `From gateway` row works.** The built-in
"Haiku" row resolves to a **dated** ID (e.g. `claude-haiku-4-5-20251001`) while
`From gateway` sends the **bare** alias (`claude-haiku-4-5`). If your key allows
only the bare form, the built-in row returns 403. Fix: add the dated ID to your
key, **or** map it with `modelOverrides` (above), **or** just use the `From
gateway` rows. *(IDs are examples — use the ones your gateway serves.)* Full
detail: `example/developer-setup/claude-setup/README.md` → **Models**.

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

**Multi-account profile.** When your admin used `tgw add-account` to onboard a
second AWS account, you get a profile named `lg-<gateway>-mantle-on-<account>` —
the naming encodes the routing (which gateway, which Bedrock account):

```toml
# ~/.codex/lg-GATEWAY-mantle-on-demo0.config.toml
model_provider = "lg-GATEWAY-mantle-on-demo0"
model = "demo0/openai.gpt-5.6-sol"
model_catalog_json = "$HOME/.codex/model-catalogs/lg-GATEWAY-mantle-on-demo0.json"
web_search = "disabled"

[model_providers.lg-GATEWAY-mantle-on-demo0]
name = "Demo0 Mantle models via LiteLLM gateway"
base_url = "https://REPLACE_WITH_GATEWAY_URL/v1"
wire_api = "responses"

[model_providers.lg-GATEWAY-mantle-on-demo0.auth]
command = "/usr/bin/cat"
args = ["$HOME/.codex/secrets/lg-GATEWAY-mantle-on-demo0-litellm-key"]
timeout_ms = 1000
refresh_interval_ms = 0
```

Launch with `codex --profile lg-GATEWAY-mantle-on-demo0`. Your admin provides the
model catalog JSON and the virtual key — store the key at the path in `args` above:

```bash
mkdir -p "$HOME/.codex/secrets" && chmod 700 "$HOME/.codex/secrets"
echo 'sk-<your-key>' > "$HOME/.codex/secrets/lg-GATEWAY-mantle-on-demo0-litellm-key"
chmod 600 "$HOME/.codex/secrets/lg-GATEWAY-mantle-on-demo0-litellm-key"
```

See `example/developer-setup/codex-setup/demo0.config.toml` for a drop-in template.

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
