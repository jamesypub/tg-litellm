"""tgw entry point — `python3 -m wizard <subcommand>`.

v1 ships one subcommand: `models`. The launcher `deploy/tgw` execs this.
"""
from __future__ import annotations

import argparse
import sys

from . import __version__, add_account_cmd, models_cmd


def _enable_line_buffering() -> None:
    """Make narration appear BEFORE the action it announces (#107).

    Python block-buffers stdout when it is not a TTY, but the engine subprocess
    inherits the same fd and writes to it directly. Without this, every
    announce/summary line sits in our buffer until exit and the engine's output
    prints first — which defeats announce-before-action in exactly the
    non-interactive/piped mode automation uses. Line buffering keeps our
    ordering correct whether stdout is a terminal, a pipe, or a file.
    """
    for stream in (sys.stdout, sys.stderr):
        # reconfigure() is 3.7+; absent when stdout is swapped for a non-
        # TextIOWrapper (test capture), where buffering is not the issue anyway.
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(line_buffering=True)
            except (ValueError, OSError):  # pragma: no cover - detached stream
                pass


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="tgw",
        description="Friendly front-end over the gateway's model tooling. "
                    "Asks a few questions, tells you what will happen, then "
                    "drives the existing scripts.",
    )
    p.add_argument("--version", action="version", version=f"tgw {__version__}")
    # Global flags shared by all (future) subcommands — mirror ccwb-iam.
    p.add_argument("--non-interactive", action="store_true",
                   help="pull every answer from env/config; never block (CI / handoff).")
    p.add_argument("--dry-run", action="store_true",
                   help="show the plan and the exact env it would export; change nothing.")
    p.add_argument("--full-reset", action="store_true",
                   help="ignore any saved answers for this env and start fresh.")
    p.add_argument("--verbose", "-v", action="store_true",
                   help="show the advanced/troubleshooting detail.")

    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("models", help="update the gateway's model catalog.")
    sub.add_parser(
        "add-account",
        help="onboard a second AWS account (Mantle/Bedrock) to an existing gateway.",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    _enable_line_buffering()
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "models":
        return models_cmd.run(args)
    if args.command == "add-account":
        return add_account_cmd.run(args)
    parser.error(f"unknown command: {args.command}")  # argparse exits 2
    return 2


if __name__ == "__main__":
    sys.exit(main())
