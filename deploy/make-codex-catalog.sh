#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq program strings are intentionally single-quoted
# Generate a complete, version-matched Codex model catalog entry for the gateway.
#
#   ./make-codex-catalog.sh <CANONICAL_MODEL_ID> [<SOURCE_SLUG>] > gateway-models.json
#
# Why: Codex's `model_catalog_json` needs a full ModelInfo entry, not a fragment.
# The correct fields are VERSION-SPECIFIC to your installed Codex, so we derive them
# from your own `codex debug models` (which already has them) and overlay only the
# gateway-compatibility changes needed for the Bedrock Mantle Responses path:
#   - use_responses_lite=false and tool_mode=null  -> Codex won't inject the
#     `additional_tools` item that Mantle rejects with HTTP 400;
#   - supports_search_tool=false + neutralized web_search_tool_type -> native web
#     search (unsupported via the gateway) is not advertised or sent.
#
# The output is a parseable {"models":[ ... ]} file whose single entry uses your
# canonical gateway model ID as the slug. Point Codex at it with
# `model_catalog_json = "<path>/gateway-models.json"`.
#
# Requires: codex CLI (same version you'll run) + jq. No network, no host changes.
set -euo pipefail

CANON="${1:-}"
SRC="${2:-}"                       # source slug in `codex debug models` to copy fields from
[ -n "$CANON" ] || { echo "usage: $0 <CANONICAL_MODEL_ID> <SOURCE_SLUG>" >&2; exit 1; }
command -v codex >/dev/null || { echo "ERROR: codex CLI not on PATH (run the same version you'll use)" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not on PATH" >&2; exit 1; }

# A SOURCE slug is required: it names the exact bundled model whose version-matched
# ModelInfo we copy. Picking a global "highest priority" model is wrong in general
# (it is only coincidentally the one you want). List available slugs with
#   codex debug models | jq -r '.models[].slug'
MODELS_JSON="$(codex debug models)"
if [ -z "$SRC" ]; then
  echo "ERROR: <SOURCE_SLUG> is required — the exact bundled model to copy ModelInfo from." >&2
  echo "       Available slugs:" >&2
  printf '%s' "$MODELS_JSON" | jq -r '.models[].slug' | sed 's/^/         - /' >&2
  exit 1
fi

# Take the source entry verbatim, then overlay: canonical slug + gateway-compat
# fields. web_search_tool_type must be REMOVED (not null): Codex 0.144.5 rejects a
# null enum ("expected value") but accepts its absence. (#30)
printf '%s' "$MODELS_JSON" | jq --arg canon "$CANON" --arg src "$SRC" '
  (.models[] | select(.slug == $src)) as $t
  | if $t == null then error("source slug \($src) not found in codex debug models") else . end
  | {models: [
      ($t
       + {slug: $canon}
       + {use_responses_lite: false, supports_search_tool: false, tool_mode: null})
      | del(.web_search_tool_type)
    ]}
'
