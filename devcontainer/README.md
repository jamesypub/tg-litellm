# Dev Environment Container — Claude Code + Codex CLI → LiteLLM Gateway

A ready-to-run container for your laptop. Claude Code and OpenAI Codex CLI come
preinstalled and are auto-configured to talk to your **LiteLLM gateway** using
your personal virtual key. No AWS credentials on your machine — the gateway
holds them.

## Prerequisites
- Docker (Desktop, or Docker Engine + compose) on your laptop.
- From your gateway admin: the **gateway URL**, your **virtual key** (`sk-…`),
  and which **model names** you're allowed to use.

## Quickstart

```bash
cd devcontainer
cp .env.example .env
# edit .env: set GATEWAY_URL, LITELLM_KEY, and (optionally) model names

docker compose run --rm dev
```

That builds the image (first run only) and drops you into a shell where both
tools are configured. Inside:

```bash
gw-check          # optional: confirm the gateway is reachable
claude            # start Claude Code
codex             # start Codex CLI
```

Your current project is mounted at `/work`. To mount a different directory:
```bash
PROJECT_DIR=/path/to/your/project docker compose run --rm dev
```

## What the container wires for you

From your `.env`, the entrypoint sets:

- **Claude Code** — `ANTHROPIC_BASE_URL=$GATEWAY_URL`, `ANTHROPIC_AUTH_TOKEN=$LITELLM_KEY`,
  `ANTHROPIC_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`.
- **Codex CLI** — writes `~/.codex/config.toml` with a `litellm` provider pointing
  at `$GATEWAY_URL/v1`, reading the key from the environment.

You just run `claude` or `codex`.

## `.env` reference

| Var | Meaning |
|---|---|
| `GATEWAY_URL` | Your gateway base URL (e.g. `https://llm-gw.example.com`) |
| `LITELLM_KEY` | Your personal virtual key (`sk-…`) |
| `CLAUDE_MODEL` | Primary Claude model name (default `claude-opus-4-8`) |
| `CLAUDE_FAST_MODEL` | Background/fast Claude model (default `claude-haiku-4-5`) |
| `CODEX_MODEL` | Codex model name (default `gpt-5-5`) |

## Notes
- **Secrets never go in the image** — only in your local `.env` (gitignored).
- If a model name is rejected, ask your admin which names are registered.
- `"Budget has been exceeded!"` means you hit your cap — ask your admin to raise it.
- Rebuild after image changes: `docker compose build`.
