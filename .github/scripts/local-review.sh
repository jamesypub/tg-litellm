#!/usr/bin/env bash
# Thin LOCAL Codex review (#23 step 3) — fast on-demand parity of the PR Action.
#
# NEVER AUTHORITATIVE. This reproduces the cross-provider review locally so the
# lead can iterate quickly before opening a PR. Correctness must never depend on
# this local loop — the durable, auditable review is the GitHub Action
# (.github/workflows/codex-review.yml). This is convenience only.
#
# Usage (from repo root):
#   .github/scripts/local-review.sh            # review working tree vs origin/main
#   BASE_REF=origin/main .github/scripts/local-review.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
export OUT_DIR="${OUT_DIR:-.github/.codex-review-local}"
export BASE_REF="${BASE_REF:-origin/main}"
echo "== LOCAL advisory review (non-authoritative) — the Action is the source of truth =="
exec bash .github/scripts/codex-review.sh
