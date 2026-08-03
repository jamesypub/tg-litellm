"""`tgw models` — the v1 flow (spec §4, §11 build outline).

Questions → resolve gateway → engine dry-run → plain-language plan → confirm
→ real run → done banner. The wizard renders; the engine
(register-models.sh) does the work, unchanged.
"""
from __future__ import annotations

import sys

from . import config, engine, gateway, preflight, ui
from .prompts import PromptAbort, Question, Resolver, resume_summary

EXIT_OK = 0
EXIT_ABORT = 2      # deliberate abort / pre-run hard-fail — always fatal
EXIT_ENGINE = 1     # engine reported a failure
EXIT_INTERRUPT = 130

FAMILIES = [
    "Claude only",
    "OpenAI/Mantle only",
    "Both Claude and OpenAI/Mantle",
]
CATALOG_MODES = [
    "Clean — reset to the current supported set",
    "Additive — keep what's there and add new",
]


def _questions(discovered_region: str) -> list[Question]:
    return [
        Question(
            key="env_name",
            prompt="Environment name",
            why="which install this is (e.g. demo2, a customer name); keeps saved answers separate per env.",
            default=None,
            validate=lambda v: None if config.valid_env_name(v)
            else "use letters, digits, dot, dash or underscore only.",
        ),
        Question(
            key="region",
            prompt="AWS region",
            why="where the gateway runs and where Bedrock models are discovered; a mismatch means no models are found.",
            default=discovered_region or "us-east-1",
        ),
        Question(
            key="families",
            prompt="Which model families should your developers get?",
            why="selects the providers to offer — Claude, OpenAI/Mantle, or both.",
            choices=FAMILIES,
            default=FAMILIES[2],
        ),
        Question(
            key="catalog_mode",
            prompt="How should the catalog be updated?",
            why="clean resets to the current supported set; additive keeps existing entries and adds new ones.",
            choices=CATALOG_MODES,
            default=CATALOG_MODES[0],
        ),
    ]


def _resolve_gateway(answers: dict, resolver: Resolver) -> None:
    """Populate answers with the transient (_-prefixed, never-persisted)
    gateway URL + master key. Path A (handoff file) preferred; Path B direct.
    """
    ui.announce("resolve_gateway")
    # Path B if the operator supplied a URL+key directly (env/config/scripted).
    direct_url = resolver.supplied.get("LITELLM_URL") or (
        resolver.scripted or {}
    ).get("_gateway_url")
    direct_key = resolver.supplied.get("LITELLM_MASTER_KEY") or (
        resolver.scripted or {}
    ).get("_master_key")
    if direct_url and direct_key:
        got = gateway.resolve_direct(str(direct_url), str(direct_key))
    else:
        got = gateway.resolve_from_handoff(
            answers["env_name"],
            answers.get("aws_profile"),
            answers.get("region"),
        )
    # Transient keys — scrubbed from any persisted config.
    answers["_gateway_url"] = got["url"]
    answers["_master_key"] = got["key"]


def run(args) -> int:
    """Entry point for the `models` subcommand. `args` is the argparse ns."""
    # --- Phase 1: preflight (read-only) --------------------------------
    err = preflight.check_python()
    if err:
        ui.fail(err, "install a newer Python 3 and re-run.", rerun_safe=True)
        return EXIT_ABORT

    supplied = _frozen_supplied(args)
    interactive = not args.non_interactive
    resolver = Resolver(
        interactive=interactive,
        supplied=supplied,
        scripted=getattr(args, "_scripted", None),
    )

    # Resume: load saved answers for this env unless --full-reset.
    env_hint = supplied.get("env_name") or (
        getattr(args, "_scripted", None) or {}
    ).get("env_name")
    saved = {} if args.full_reset else config.load(env_hint)
    answers: dict = dict(saved)
    if saved:
        msg = resume_summary(saved, config.SECRET_KEYS)
        if msg:
            print(msg)

    profile = supplied.get("aws_profile")
    ident = preflight.aws_identity(profile, supplied.get("region"))
    if "error" in ident:
        ui.fail(
            f"couldn't verify AWS credentials: {ident['error']}",
            preflight.sso_login_hint(profile),
            rerun_safe=True,
        )
        return EXIT_ABORT
    print(f"\n  AWS account {ident['account']}  ({ident['arn']})")

    # --- Phase 2: questions --------------------------------------------
    try:
        for q in _questions(str(supplied.get("region", ""))):
            answers[q.key] = resolver.ask(q)
            config.save(answers, answers.get("env_name"))  # resume after each
        if profile:
            answers["aws_profile"] = profile

        # --- resolve gateway (secret; transient) -----------------------
        _resolve_gateway(answers, resolver)
    except PromptAbort as e:
        if str(e) == "interrupted":
            print("\n  Interrupted — your answers were saved; re-run to resume.",
                  file=sys.stderr)
            return EXIT_INTERRUPT
        ui.fail(str(e), "set the missing value via env/config and re-run.",
                rerun_safe=True)
        return EXIT_ABORT
    except RuntimeError as e:
        ui.fail(str(e), "check the value and re-run — nothing was changed.",
                rerun_safe=True)
        return EXIT_ABORT

    # --- Phase 3: dry-run + plain-language plan ------------------------
    ui.announce("discover")
    if args.dry_run:
        # --dry-run: show the plan and the exact env, mutate nothing.
        rc = engine.run(answers, dry_run=True, confirm=False)
        _print_env_for_debug(answers, args)
        return EXIT_OK if rc == 0 else EXIT_ENGINE

    ui.announce("plan")
    # The engine's own dry-run produces the authoritative summary; we run it
    # first so the operator sees the real delete/register lists before the
    # confirm gate. (We do NOT compute those lists ourselves — spec §5.3.)
    rc = engine.run(answers, dry_run=True, confirm=False)
    if rc != 0:
        ui.fail("couldn't preview the catalog changes.",
                "check the gateway address / admin key and re-run.",
                rerun_safe=True)
        return EXIT_ENGINE

    # --- confirm (interactive) or WIZARD_CONFIRM (non-interactive) -----
    if interactive:
        try:
            ans = input("\n  Proceed with these changes? [y/N]: ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            print("\n  Aborted — nothing was changed.", file=sys.stderr)
            return EXIT_INTERRUPT
        if ans not in ("y", "yes"):
            print("  Aborted — nothing was changed.")
            return EXIT_ABORT
    elif not _truthy(supplied.get("WIZARD_CONFIRM")):
        ui.fail("this run would change the gateway's catalog, but no confirmation was given.",
                "re-run with WIZARD_CONFIRM=1 (non-interactive) to proceed, or use --dry-run to preview.",
                rerun_safe=True)
        return EXIT_ABORT

    # --- Phase 4: the real run -----------------------------------------
    ui.announce("register")
    rc = engine.run(answers, dry_run=False, confirm=True)
    if rc != 0:
        ui.fail("the model registration step reported an error.",
                "review the output above; re-running is safe (it's idempotent).",
                rerun_safe=True)
        return EXIT_ENGINE

    # --- Phase 5: done -------------------------------------------------
    config.clear(answers.get("env_name"))  # clean success → drop resume file
    ui.done("The gateway will serve the updated models momentarily.")
    return EXIT_OK


def _frozen_supplied(args) -> dict:
    """A frozen snapshot of env/config-derived answers at construction — never
    aliased to the mutable working dict (spec §7)."""
    import os

    supplied: dict = {}
    for ans_key, env_var in (
        ("env_name", "ENV"),
        ("region", "REGION"),
        ("aws_profile", "AWS_PROFILE"),
        ("include", "WIZARD_INCLUDE"),
        ("exclude", "WIZARD_EXCLUDE"),
    ):
        v = os.environ.get(env_var)
        if v:
            supplied[ans_key] = v
    for passthru in ("LITELLM_URL", "LITELLM_MASTER_KEY", "WIZARD_CONFIRM"):
        v = os.environ.get(passthru)
        if v:
            supplied[passthru] = v
    return supplied


def _truthy(v) -> bool:
    return str(v).strip().lower() in ("1", "y", "yes", "true")


def _print_env_for_debug(answers: dict, args) -> None:
    """--verbose/--dry-run only: show the exact env the wizard would export,
    with the secret redacted. Never printed on the normal flow (spec §5.1)."""
    if not (args.verbose or args.dry_run):
        return
    env = engine.build_env(answers)
    print("\n  (debug) environment the engine would receive:")
    for k in sorted(env):
        val = env[k]
        if k in ("LITELLM_MASTER_KEY",):
            val = "***redacted***"
        print(f"    {k}={val}")
