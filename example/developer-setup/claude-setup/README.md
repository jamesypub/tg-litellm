# Claude Code — developer setup

Drop-in config for running Claude Code against this gateway. The gateway serves
Claude via bare model aliases (no AWS creds on your laptop — the gateway holds
them).

## Files here

| File | Copy to | Notes |
|---|---|---|
| `settings.json` | `~/.claude-lg-dev/settings.json` | isolated config dir; owner-only (chmod 600) |
| `claude-lg.bashrc` | append to `~/.bash_profile` | the `claude-lg-dev()` launcher |

## Steps

1. **Install Claude Code** (if you haven't): see the official install docs.

2. **Place the settings file** (isolated config dir, so it can't collide with any
   other Claude Code config you run):
   ```bash
   mkdir -p ~/.claude-lg-dev && chmod 700 ~/.claude-lg-dev
   cp claude-setup/settings.json ~/.claude-lg-dev/settings.json
   chmod 600 ~/.claude-lg-dev/settings.json
   ```

3. **Edit `~/.claude-lg-dev/settings.json`** — replace two values:
   - `ANTHROPIC_BASE_URL` → your gateway URL (currently `https://EXAMPLE.cloudfront.net`)
   - `ANTHROPIC_AUTH_TOKEN` → your virtual key (currently `sk-<your-key>`)

4. **Add the launcher** to your shell profile:
   ```bash
   cat claude-setup/claude-lg.bashrc >> ~/.bash_profile
   ```

5. **Launch** in a fresh shell:
   ```bash
   source ~/.bash_profile
   claude-lg-dev
   ```

The launcher scrubs any inherited `CLAUDE_CODE_USE_BEDROCK` / `_VERTEX` /
`ANTHROPIC_API_KEY` / AWS provider vars and fails closed if one is still set — so
an environment left over from another setup can't silently bypass the gateway.

## Models

The blessed defaults are the bare aliases the gateway serves:
- primary: `claude-opus-4-8`
- fast: `claude-haiku-4-5-20251001`

**Changing the model** (only if your key allows different ones): edit
`ANTHROPIC_MODEL` and/or `ANTHROPIC_SMALL_FAST_MODEL` in `settings.json`. Use the
**bare** alias the gateway serves (not a `global/…` or `us/…` scoped name — Claude
Code rejects slash aliases). Ask your admin which aliases your key allows.

### Seeing the gateway's models in the `/model` picker

By default the `/model` picker shows Claude Code's built-in aliases (Opus /
Sonnet / Haiku), **not** the set your gateway registered. When your admin adds
new Anthropic models via `tgw`, they don't appear until you opt into one of the
following. All three are standard Claude Code settings (see
`code.claude.com/docs/en/model-config`); none change anything until you set them.

**1. Discovery — the whole registered catalog, self-updating (recommended).**
Set one env var and every model the gateway serves fills the picker, with future
additions appearing automatically — no per-model edits:
```bash
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
```
The launcher already forwards your environment to `claude`, so exporting it in
the shell (or adding it to `settings.json`'s `"env"` block) is enough. With
`ANTHROPIC_BASE_URL` pointing at the gateway, Claude Code populates `/model` from
the gateway's `/v1/models`. This is the direct answer to "include newly added
models."

**2. `modelOverrides` — pin the built-in rows to your gateway's bare aliases.**
A remap table (not a list of new choices): it makes the built-in Opus/Sonnet/
Haiku rows send the **bare** alias your gateway serves. Add to `settings.json`:
```json
{
  "modelOverrides": {
    "claude-opus-4-8": "claude-opus-4-8",
    "claude-sonnet-4-5-20250929": "claude-sonnet-4-5-20250929",
    "claude-haiku-4-5-20251001": "claude-haiku-4-5-20251001"
  }
}
```
- **Key** = the model ID as Claude Code knows it (dated IDs need the exact date).
- **Value** = the exact string sent to the gateway — the **bare** alias `tgw`
  registered (never a `us/…` / `global/…` slash name; Claude Code rejects those).
- Unknown keys are ignored — `modelOverrides` only remaps existing rows.

**3. `ANTHROPIC_CUSTOM_MODEL_OPTION` — add exactly ONE new named row.**
The only way to add a *new* named entry (env vars, set them in the launcher/shell):
```bash
export ANTHROPIC_CUSTOM_MODEL_OPTION="claude-opus-5"
export ANTHROPIC_CUSTOM_MODEL_OPTION_NAME="Opus 5 (gateway)"           # optional
export ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION="Routed via the gateway"  # optional
```
Adds one row at the bottom of `/model`; validation is skipped so any string the
gateway accepts works. **There is no array form** — for several new models, use
discovery (option 1).

**Which to use:** want the whole catalog, self-updating → **discovery**. Want a
curated menu → **`modelOverrides`** to pin the standard rows, plus one
`ANTHROPIC_CUSTOM_MODEL_OPTION` for an extra model.

**Caveats:**
- The picker lists what the gateway **serves**; you can still only **use**
  models your virtual key allows — picking a disallowed one returns a policy
  **403**. Your key's allowed-models list is the real gate.
- The gateway serves bare aliases **and** `us/…` / `global/…` scoped names;
  Claude Code rejects slash names, so pick the **bare** alias.

### FAQ — a built-in row fails but the `From gateway` row works

**Model IDs below are examples — the exact dated ID varies by model; use the
ones your gateway serves (`/v1/models`, or the picker's `From gateway` rows).**

**Symptom.** In `/model`, a **built-in** row (e.g. "Haiku") fails, but the
**`From gateway`** row for the same model (e.g. `claude-haiku-4-5`) works.

**Why.** A `From gateway` row sends the exact bare alias the gateway serves
(`claude-haiku-4-5`). A **built-in** alias row resolves to Claude Code's dated
model ID (e.g. `claude-haiku-4-5-20251001`) — a different string. If your key's
allowed-models list doesn't include that dated ID, the built-in row returns a
policy **403** even though the gateway serves the model. (Built-in Sonnet/Opus
rows resolve to dated IDs the same way.)

**Fix — pick one:**
- **A. Add the dated ID to your key** (makes the built-in row work). Ask your
  admin to add e.g. `claude-haiku-4-5-20251001` alongside `claude-haiku-4-5` in
  the key's **Models** list. Repeat per built-in alias you want usable.
- **B. Pin the built-in aliases to the bare IDs the key already allows** (no key
  change) via `modelOverrides`:
  ```json
  { "modelOverrides": { "claude-haiku-4-5-20251001": "claude-haiku-4-5" } }
  ```
  Add one line per built-in alias you use, keyed by the dated ID Claude Code
  sends, valued with the bare alias the gateway serves.
- **Simplest workaround:** until either is applied, just use the `From gateway`
  rows — they already work.
