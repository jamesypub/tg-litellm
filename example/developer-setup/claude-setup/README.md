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
