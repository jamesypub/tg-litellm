"""User-facing messaging — outcomes, not internals (spec §5).

Every line here names a real-world EFFECT the operator cares about. It must
never leak internals: no function/step names, no WIZARD_*/TG_* variable
names, no curl/aws/terraform command lines, no inference-profile strings.
Those appear only under --verbose / --dry-run, handled by the caller.
"""
from __future__ import annotations

import sys

# Announce-before-action lines (spec §5.1). Keyed so the flow reads clearly.
ACTIONS = {
    "resolve_gateway": "Reading your gateway's address and admin key so the wizard can talk to it…",
    "discover": "Retrieving the Claude and OpenAI/Mantle models available in Bedrock for this account…",
    "reachable": "Checking which models are reachable right now…",
    "plan": "Working out what will change on the gateway…",
    "register": "Updating the gateway's model catalog (this is safe to re-run)…",
}


def announce(key: str) -> None:
    msg = ACTIONS.get(key)
    if msg:
        print(f"\n  {msg}")


def banner(title: str) -> None:
    print()
    print(f"  === {title} ===")


def done(served_hint: str = "") -> None:
    """The success banner (spec §5, phase 5)."""
    print()
    print("  ✓ Done — your gateway's model catalog is up to date.")
    if served_hint:
        print(f"    {served_hint}")
    print("    Next: sign in to the admin UI and mint a developer key")
    print("          (see docs/admin.md).")


def fail(cause: str, recovery: str, rerun_safe: bool = True) -> None:
    """Friendly failure: name the cause AND the recovery (spec §5.4)."""
    print(file=sys.stderr)
    print(f"  ✗ {cause}", file=sys.stderr)
    print(f"    → {recovery}", file=sys.stderr)
    if rerun_safe:
        print(
            "    Nothing was changed by this step; re-running is safe.",
            file=sys.stderr,
        )
