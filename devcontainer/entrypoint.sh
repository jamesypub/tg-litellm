#!/usr/bin/env bash
# Wire Claude Code + Codex CLI to the LiteLLM gateway from environment variables,
# then hand off to the requested command (default: an interactive shell).
set -euo pipefail

# Runs as root first: (1) align the 'dev' user to the OWNER of the bind-mounted
# /work so the dropped user can actually read the developer's checkout even when it
# is mode 0700 owned by the host UID (#30 — otherwise `ls /work` / reading project
# files fails after the drop); (2) fix ownership of mounted named volumes (which
# mount as root by default); then re-exec this script as 'dev'.
if [ "$(id -u)" = "0" ]; then
  if [ -d /work ]; then
    HOST_UID="$(stat -c '%u' /work 2>/dev/null || echo 0)"
    HOST_GID="$(stat -c '%g' /work 2>/dev/null || echo 0)"
    # Only remap for a real non-root host owner; leave root-owned mounts as-is.
    if [ "${HOST_UID:-0}" != "0" ] && [ "$HOST_UID" != "$(id -u dev)" ]; then
      groupmod -o -g "$HOST_GID" dev 2>/dev/null || true
      usermod  -o -u "$HOST_UID" -g "$HOST_GID" dev 2>/dev/null || true
    fi
  fi
  mkdir -p /home/dev/.claude /home/dev/.codex
  chown -R dev:dev /home/dev /home/dev/.claude /home/dev/.codex
  exec setpriv --reuid dev --regid dev --init-groups "$0" "$@"
fi

: "${GATEWAY_URL:?set GATEWAY_URL in .env (e.g. https://llm-gw.example.com)}"
: "${LITELLM_KEY:?set LITELLM_KEY in .env (your sk-... virtual key)}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-8}"
CLAUDE_FAST_MODEL="${CLAUDE_FAST_MODEL:-claude-haiku-4-5}"
CODEX_MODEL="${CODEX_MODEL:-openai.gpt-5.5}"   # canonical Mantle ID (#30)

# --- Claude Code: talks the Anthropic API; point it at the gateway ---
export ANTHROPIC_BASE_URL="$GATEWAY_URL"
export ANTHROPIC_AUTH_TOKEN="$LITELLM_KEY"
export ANTHROPIC_MODEL="$CLAUDE_MODEL"
export ANTHROPIC_SMALL_FAST_MODEL="$CLAUDE_FAST_MODEL"

# --- Codex CLI: talks the OpenAI Responses API; gateway as a custom provider ---
# CODEX_MODEL is the EXACT canonical Mantle ID (e.g. openai.gpt-5.6-sol) — Codex
# sends it verbatim and the key must be allowed that exact ID (#30). wire_api must
# be "responses" for the Mantle route; "chat" does not exercise the real path.
export LITELLM_KEY   # config.toml reads the key from this env var
mkdir -p "$HOME/.codex"
CATALOG="$HOME/.codex/gateway-models.json"
# The generator is COPIED INTO THE IMAGE at build time (/usr/local/bin), so it does
# not depend on the bind-mounted project's file mode (a 0700 checkout left the
# mounted copy unreadable to the dropped 'dev' UID → #30). Prefer the image copy.
GEN=/usr/local/bin/make-codex-catalog.sh
[ -x "$GEN" ] || GEN=/work/deploy/make-codex-catalog.sh
# Generate a complete, version-matched catalog so Codex does not inject the
# additional_tools item Mantle rejects (#30). FAIL CLOSED (no silent bundled
# fallback). Set CODEX_SKIP_CATALOG=1 to intentionally run without a catalog.
# CRITICAL (#30): remove any stale config FIRST so the generator's internal
# `codex debug models` does not read a config pointing at the catalog we are about
# to (re)write, and generate to a TEMP file then mv atomically — never truncate the
# live catalog in place (that self-destructed on the second container run).
rm -f "$HOME/.codex/config.toml"
CATALOG_LINE=""
if [ "${CODEX_SKIP_CATALOG:-0}" = "1" ]; then
  echo "note: CODEX_SKIP_CATALOG=1 — running Codex WITHOUT a generated catalog." >&2
else
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required to generate the Codex catalog (#30). Set CODEX_SKIP_CATALOG=1 to bypass." >&2; exit 1; }
  [ -x "$GEN" ] || { echo "ERROR: make-codex-catalog.sh not found/executable (image or /work) (#30)." >&2; exit 1; }
  SRC="${CODEX_SOURCE_SLUG:-$(codex debug models 2>/dev/null | jq -r '.models | sort_by(.priority // 999) | .[0].slug // empty')}"
  [ -n "$SRC" ] || { echo "ERROR: cannot resolve a Codex source slug; set CODEX_SOURCE_SLUG (#30)." >&2; exit 1; }
  TMP_CAT="$(mktemp "$HOME/.codex/gateway-models.XXXXXX.json")"
  if "$GEN" "$CODEX_MODEL" "$SRC" > "$TMP_CAT" && [ -s "$TMP_CAT" ]; then
    mv -f "$TMP_CAT" "$CATALOG"
    CATALOG_LINE="model_catalog_json = \"$CATALOG\""
  else
    rm -f "$TMP_CAT"
    echo "ERROR: catalog generation failed for $CODEX_MODEL from $SRC (#30)." >&2; exit 1
  fi
fi
cat > "$HOME/.codex/config.toml" <<TOML
model = "${CODEX_MODEL}"
model_provider = "litellm"
${CATALOG_LINE}
web_search = "disabled"

[model_providers.litellm]
name = "LiteLLM Gateway"
base_url = "${GATEWAY_URL%/}/v1"
env_key = "LITELLM_KEY"
wire_api = "responses"
TOML

# Banner to STDERR so it never pollutes captured command stdout (scripts/pipes).
{
  echo "dev environment ready:"
  echo "  gateway     : $GATEWAY_URL"
  echo "  Claude model: $ANTHROPIC_MODEL   (fast: $ANTHROPIC_SMALL_FAST_MODEL)"
  echo "  Codex model : $CODEX_MODEL"
  echo "  run 'claude' or 'codex' — both are configured. 'gw-check' tests connectivity."
} >&2

# tiny connectivity helper on PATH for this session
mkdir -p "$HOME/bin"
cat > "$HOME/bin/gw-check" <<'CHK'
#!/usr/bin/env bash
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$GATEWAY_URL/health/liveliness" || echo 000)
echo "gateway $GATEWAY_URL/health/liveliness -> HTTP $code"
CHK
chmod +x "$HOME/bin/gw-check"
export PATH="$HOME/bin:$PATH"

exec "$@"
