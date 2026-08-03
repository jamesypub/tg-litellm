# Codex — developer setup

Drop-in config for running Codex (gpt-5.x on Bedrock Mantle) against this gateway
over the Responses API.

## Pinned Codex version

**Use Codex `0.145.0`.** The model catalog (`dev-models.json`) carries
**version-specific** ModelInfo — `make-codex-catalog.sh` generates it against a
specific Codex version, and a mismatched CLI can fail to launch or behave
incorrectly. This example's `dev-models.json` was generated against **`0.145.0`**.
If you run a different version, ask your admin for a catalog regenerated against
it; do not assume this file is drop-in compatible with latest.

Check yours:
```bash
codex --version    # expect: codex-cli 0.145.0
```

## Files here

| File | Copy to | Notes |
|---|---|---|
| `dev.config.toml` | `~/.codex/dev.config.toml` | named profile `dev`, provider `litellm-gw` |
| `dev-models.json` | `~/.codex/dev-models.json` | version-matched catalog for the default model |
| `dev.key.example` | `~/.codex/dev.key` | put your key in it; owner-only (chmod 600) |
| `codex-lg.bashrc` | append to `~/.bash_profile` | the `codex-lg-dev()` launcher |

## Steps

1. **Install Codex `0.145.0`** (see the pinned-version note above).

2. **Place the files:**
   ```bash
   mkdir -p ~/.codex && chmod 700 ~/.codex
   cp codex-setup/dev.config.toml  ~/.codex/dev.config.toml
   cp codex-setup/dev-models.json  ~/.codex/dev-models.json
   cp codex-setup/dev.key.example  ~/.codex/dev.key
   chmod 600 ~/.codex/dev.key
   ```

3. **Edit `~/.codex/dev.config.toml`** — replace one value:
   - `base_url` → your gateway URL + `/v1` (currently `https://EXAMPLE.cloudfront.net/v1`)

4. **Edit `~/.codex/dev.key`** — replace `sk-<your-key>` with your virtual key.

5. **Add the launcher** and launch in a fresh shell:
   ```bash
   cat codex-setup/codex-lg.bashrc >> ~/.bash_profile
   source ~/.bash_profile
   codex-lg-dev
   ```

The launcher sources your key file and scrubs `OPENAI_API_KEY` / AWS provider vars,
failing closed if one is still set.

## Changing the model is atomic (TOML **and** catalog)

The default is `openai.gpt-5.6-sol` (the exact canonical Mantle slug). Editing
`model` in the TOML alone is **not enough** — the selected slug must also exist,
with correct version-specific metadata, in `dev-models.json`. To change models:

1. set `model` in `dev.config.toml` to the new canonical slug, **and**
2. get a `dev-models.json` regenerated (by your admin, via `make-codex-catalog.sh`
   against your Codex version) that includes that slug.

If you only edit one of the two, Codex will not launch cleanly. When in doubt,
keep the blessed default and ask your admin for a package covering the model you
need. `codex /model` lists the models your key allows.
