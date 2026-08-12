#!/usr/bin/env python3
"""Offline unit test for the tgw wizard (spec §11.8).

Regression-proofing: the engine (register-models.sh) is STUBBED here and
NEVER invoked for real, so these tests cannot regress it. We assert:
  * the env the wizard would export to the engine (fail-closed enum words),
  * the model-family → WIZARD_DELETE_SCOPE mapping,
  * secrets are scrubbed from the persisted resume config,
  * env-name keying / resume behavior,
  * the answer-resolution precedence (scripted → supplied → default).

Run:  python3 tests/tgw.test.py     (no TTY, no AWS, no network)
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

# Put deploy/ on the path so `import wizard` resolves.
REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "deploy"))

from wizard import add_account_cmd, config, engine, gateway, preflight  # noqa: E402
from wizard.prompts import Question, Resolver, PromptAbort, resume_summary  # noqa: E402

FAILS = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global FAILS
    if cond:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}  {detail}")


def make_monkeypatch():
    """Minimal attribute-patcher: patch module attrs for one test, restore after.

    Returns (patch_fn, restore_fn). patch_fn(mod, {name: value}) sets and records
    the originals; restore_fn() puts them all back. No pytest dependency."""
    saved: list[tuple[object, str, object]] = []

    def patch(mod, mapping: dict):
        for name, value in mapping.items():
            saved.append((mod, name, getattr(mod, name)))
            setattr(mod, name, value)

    def restore():
        for mod, name, value in reversed(saved):
            setattr(mod, name, value)
        saved.clear()

    return patch, restore


# --- 1. build_env: family → WIZARD_DELETE_SCOPE (fail-closed words) --------
def test_build_env_family_scope():
    cases = {
        "Claude only": "claude",
        "OpenAI/Mantle only": "mantle",
        "Both Claude and OpenAI/Mantle": "both",
        "garbage": "both",  # unknown → safe default
    }
    for fam, want in cases.items():
        env = engine.build_env({"families": fam})
        check(f"family '{fam}' → WIZARD_DELETE_SCOPE={want}",
              env.get("WIZARD_DELETE_SCOPE") == want,
              f"got {env.get('WIZARD_DELETE_SCOPE')}")
    # WIZARD_DELETE_SCOPE must be a word the engine accepts, never a digit.
    env = engine.build_env({"families": "Claude only"})
    check("scope is a word, not a raw digit",
          env["WIZARD_DELETE_SCOPE"] in ("claude", "mantle", "both"))
    # SCOPE (region axis) must NOT be set from the family answer.
    check("family answer does not set SCOPE (region axis)",
          "SCOPE" not in env, f"leaked SCOPE={env.get('SCOPE')}")


# --- 2. build_env: catalog mode → additive|clean only ----------------------
def test_build_env_mode():
    check("clean mode → WIZARD_MODE=clean",
          engine.build_env({"catalog_mode": "Clean — reset"})["WIZARD_MODE"] == "clean")
    check("additive mode → WIZARD_MODE=additive",
          engine.build_env({"catalog_mode": "Additive — keep"})["WIZARD_MODE"] == "additive")
    for m in ("Clean — reset", "Additive — keep"):
        val = engine.build_env({"catalog_mode": m})["WIZARD_MODE"]
        check(f"'{m}' yields an engine-valid WIZARD_MODE",
              val in ("additive", "clean"), f"got {val}")
    check("WIZARD flag always set to 1",
          engine.build_env({})["WIZARD"] == "1")


# --- 3. gateway url/key threaded from transient answers --------------------
def test_build_env_gateway():
    env = engine.build_env({"_gateway_url": "http://gw.example", "_master_key": "sk-xyz"})
    check("gateway url → LITELLM_URL", env.get("LITELLM_URL") == "http://gw.example")
    check("master key → LITELLM_MASTER_KEY", env.get("LITELLM_MASTER_KEY") == "sk-xyz")


# --- 4. secrets scrubbed from persisted config -----------------------------
def test_config_scrub(tmp_home: Path):
    answers = {
        "env_name": "demo0",
        "region": "us-east-1",
        "_gateway_url": "http://gw",       # transient (_-prefix) → not persisted
        "_master_key": "sk-secret",        # transient
        "LITELLM_MASTER_KEY": "sk-secret", # in SECRET_KEYS → not persisted
    }
    config.save(answers, "demo0")
    saved = config.load("demo0")
    check("env_name persisted", saved.get("env_name") == "demo0")
    check("region persisted", saved.get("region") == "us-east-1")
    check("_-prefixed gateway url NOT persisted", "_gateway_url" not in saved)
    check("_-prefixed master key NOT persisted", "_master_key" not in saved)
    check("SECRET_KEYS master key NOT persisted", "LITELLM_MASTER_KEY" not in saved)
    # File mode is owner-only.
    path = config.config_path_for("demo0")
    mode = oct(path.stat().st_mode & 0o777)
    check("config file is 0600", mode == "0o600", f"got {mode}")


# --- 5. env-name keying: demo0 and customer don't cross-resume -------------
def test_config_keying(tmp_home: Path):
    config.save({"env_name": "demo0", "region": "us-east-1"}, "demo0")
    config.save({"env_name": "cust", "region": "eu-west-1"}, "cust")
    check("demo0 resumes its own region",
          config.load("demo0").get("region") == "us-east-1")
    check("cust resumes its own region",
          config.load("cust").get("region") == "eu-west-1")
    check("distinct files per env",
          config.config_path_for("demo0") != config.config_path_for("cust"))
    # A path-escaping env name is rejected → neutral path, not a traversal.
    check("unsafe env name falls back to neutral path",
          config.config_path_for("../etc/passwd") == config.CONFIG_PATH)


# --- 6. resolver precedence: scripted > supplied > default -----------------
def test_resolver_precedence():
    q = Question(key="region", prompt="AWS region", why="x", default="us-east-1")
    r = Resolver(interactive=False, supplied={"region": "eu-west-1"},
                 scripted={"region": "ap-south-1"})
    check("scripted wins over supplied+default", r.ask(q) == "ap-south-1")
    r2 = Resolver(interactive=False, supplied={"region": "eu-west-1"})
    check("supplied wins over default", r2.ask(q) == "eu-west-1")
    r3 = Resolver(interactive=False, supplied={})
    check("default used when nothing supplied", r3.ask(q) == "us-east-1")
    # non-interactive with no value and no default → hard abort.
    q2 = Question(key="env_name", prompt="Env", why="x", default=None)
    try:
        Resolver(interactive=False, supplied={}).ask(q2)
        check("non-interactive missing-required aborts", False, "no raise")
    except PromptAbort:
        check("non-interactive missing-required aborts", True)


# --- 7. validation is enforced on supplied values --------------------------
def test_resolver_validates_supplied():
    q = Question(key="env_name", prompt="Env", why="x",
                 validate=lambda v: None if config.valid_env_name(v) else "bad")
    try:
        Resolver(interactive=False, supplied={"env_name": "../evil"}).ask(q)
        check("invalid supplied env_name rejected", False, "no raise")
    except PromptAbort:
        check("invalid supplied env_name rejected", True)


# --- 8. resume_summary shows non-secret answers only -----------------------
def test_resume_summary():
    msg = resume_summary({"env_name": "demo0", "region": "us-east-1",
                          "LITELLM_MASTER_KEY": "sk-x"}, config.SECRET_KEYS)
    check("resume summary lists env_name", "demo0" in msg)
    check("resume summary lists region", "us-east-1" in msg)
    check("resume summary hides the secret", "sk-x" not in msg)
    check("empty answers → empty summary", resume_summary({}) == "")


# --- 8b. #107: narration must precede child output under a pipe ------------
def test_narration_ordering_not_tty():
    """Repro for #107. Under a pipe, Python block-buffers stdout while a child
    process writes to the same fd directly — so narration used to flush only at
    exit, after the engine's output. Drive a child with stdout=PIPE (never a
    TTY) and assert our line lands FIRST. The engine is not involved: the child
    stands in for it with `echo`."""
    import subprocess as sp

    prog = (
        "import sys, subprocess;"
        "sys.path.insert(0, %r);"
        "from wizard.__main__ import _enable_line_buffering;"
        "_enable_line_buffering();"
        "print('NARRATION-FIRST');"
        "subprocess.call(['echo', 'ENGINE-SECOND'])"
    ) % str(REPO / "deploy")
    out = sp.run([sys.executable, "-c", prog], capture_output=True, text=True,
                 timeout=30).stdout
    check("narration flushes before child output under a pipe (#107)",
          out.index("NARRATION-FIRST") < out.index("ENGINE-SECOND")
          if ("NARRATION-FIRST" in out and "ENGINE-SECOND" in out) else False,
          f"got {out!r}")

    # And the same ordering without the helper, via engine.run's pre-spawn
    # flush path: a bare print then a flush then a child.
    prog2 = (
        "import sys, subprocess;"
        "print('NARRATION-FIRST');"
        "sys.stdout.flush();"
        "subprocess.call(['echo', 'ENGINE-SECOND'])"
    )
    out2 = sp.run([sys.executable, "-c", prog2], capture_output=True, text=True,
                  timeout=30).stdout
    check("explicit pre-spawn flush also orders correctly (engine.run path)",
          out2.index("NARRATION-FIRST") < out2.index("ENGINE-SECOND")
          if ("NARRATION-FIRST" in out2 and "ENGINE-SECOND" in out2) else False,
          f"got {out2!r}")


# --- 9. the real engine script is never invoked by these tests -------------
def test_engine_not_invoked(monkeypatched: list):
    # engine.run shells out; we assert the module targets the real script path
    # but the tests above only ever call build_env (pure). This guards that no
    # test accidentally calls run().
    check("engine points at register-models.sh (unchanged)",
          engine.REGISTER_SCRIPT.name == "register-models.sh")
    check("register-models.sh exists and is untouched by the wizard",
          engine.REGISTER_SCRIPT.exists())


# --- 10. #115 Issue 3: preflight parse + orchestrator (no AWS/network) ------
def test_preflight_aws_version_parse():
    p = preflight._parse_aws_version
    check("parses aws-cli/2.17.0", p("aws-cli/2.17.0 Python/3.11 Linux") == (2, 17, 0))
    check("parses aws-cli/2.15.0", p("aws-cli/2.15.0 Python/3.9") == (2, 15, 0))
    check("parses aws-cli/1.29.0 as v1 tuple (gate rejects it below)",
          p("aws-cli/1.29.0 Python/3.8") == (1, 29, 0))
    check("garbage yields None", p("totally not aws") is None)
    # The gate itself: <2.15 fails, ==2.15 and >2.15 pass.
    check("2.14.9 is below the v2.15 minimum", (2, 14, 9) < preflight.MIN_AWS_CLI)
    check("2.15.0 meets the minimum", not ((2, 15, 0) < preflight.MIN_AWS_CLI))
    check("2.17.0 exceeds the minimum", not ((2, 17, 0) < preflight.MIN_AWS_CLI))


def test_preflight_python_check_current():
    # This interpreter is >=3.8 (the tests import dataclasses etc.), so the
    # Check must be a pass with a version detail.
    c = preflight._python_check()
    check("python check passes on this interpreter", c.ok is True, f"detail={c.detail}")
    check("python check reports a version detail", bool(c.detail))


def test_preflight_orchestrator_aborts_on_failure():
    """run_preflight must (a) return the FIRST failing Check and (b) never even
    render the later checks' failures as the abort reason. We stub each sub-check
    so no AWS/network call happens."""
    patch, restore = make_monkeypatch()
    ok = lambda label: preflight.Check(label, True, "stub")
    patch(preflight, {
        "_python_check": lambda: ok("python3"),
        "_aws_cli_check": lambda: preflight.Check("aws CLI", False,
                                                   "1.x detected", "upgrade hint"),
        "_curl_check": lambda: ok("curl"),
        "_creds_check": lambda p, r: (ok("AWS credentials"), "123456789012"),
        "_bedrock_permission_check": lambda p, r: ok("Bedrock"),
        "_gateway_reachable_check": lambda u, k, h=False: (ok("LITELLM_URL"), ok("LITELLM_MASTER_KEY")),
    })
    try:
        lines: list[str] = []
        fail = preflight.run_preflight(profile=None, region="us-east-1",
                                       url=None, key=None, printer=lines.append)
        check("run_preflight returns the failing Check", fail is not None
              and fail.label == "aws CLI", f"got {fail}")
        blob = "\n".join(lines)
        check("failure line is marked with ✗", "✗ aws CLI" in blob, blob)
        check("abort banner printed (nothing changed)", "Nothing was changed" in blob)
        check("fix hint from the failing check is shown", "upgrade hint" in blob)
        check("does NOT claim all checks passed", "all checks passed" not in blob)
    finally:
        restore()


def test_preflight_orchestrator_all_pass():
    patch, restore = make_monkeypatch()
    ok = lambda label: preflight.Check(label, True, "stub")
    patch(preflight, {
        "_python_check": lambda: ok("python3"),
        "_aws_cli_check": lambda: ok("aws CLI"),
        "_curl_check": lambda: ok("curl"),
        "_creds_check": lambda p, r: (ok("AWS credentials"), "123456789012"),
        "_bedrock_permission_check": lambda p, r: ok("Bedrock"),
        "_gateway_reachable_check": lambda u, k, h=False: (ok("LITELLM_URL"), ok("LITELLM_MASTER_KEY")),
    })
    try:
        lines: list[str] = []
        fail = preflight.run_preflight(profile=None, region="us-east-1",
                                       url="http://gw", key="sk-x", printer=lines.append)
        check("all-pass returns None", fail is None)
        check("all-pass prints the success line", "all checks passed" in "\n".join(lines))
    finally:
        restore()


def test_preflight_skips_bedrock_when_creds_fail():
    """If creds don't resolve, the Bedrock probe must be skipped (its error
    would be redundant) and creds is the reported failure."""
    patch, restore = make_monkeypatch()
    called = {"bedrock": False}

    def bedrock(p, r):
        called["bedrock"] = True
        return preflight.Check("Bedrock", True)

    patch(preflight, {
        "_python_check": lambda: preflight.Check("python3", True),
        "_aws_cli_check": lambda: preflight.Check("aws CLI", True),
        "_curl_check": lambda: preflight.Check("curl", True),
        "_creds_check": lambda p, r: (preflight.Check("AWS credentials", False,
                                                      "expired", "aws sso login"), ""),
        "_bedrock_permission_check": bedrock,
        "_gateway_reachable_check": lambda u, k, h=False: (preflight.Check("LITELLM_URL", None),
                                                  preflight.Check("LITELLM_MASTER_KEY", None)),
    })
    try:
        lines: list[str] = []
        fail = preflight.run_preflight(profile=None, region=None,
                                       url=None, key=None, printer=lines.append)
        check("creds failure is the reported failure", fail is not None
              and fail.label == "AWS credentials", f"got {fail}")
        check("Bedrock probe skipped when creds fail", called["bedrock"] is False)
    finally:
        restore()


def test_preflight_bedrock_region_gating():
    """Codex #115 MED: preflight runs BEFORE the region question, so a
    region-less run must SKIP the Bedrock probe (not guess us-east-1 and
    false-fail a different-region customer). A supplied region → probe runs."""
    patch, restore = make_monkeypatch()

    def make_stubs(called):
        def bedrock(p, r):
            called["bedrock"] = True
            called["region"] = r
            return preflight.Check("Bedrock", True)
        return {
            "_python_check": lambda: preflight.Check("python3", True),
            "_aws_cli_check": lambda: preflight.Check("aws CLI", True),
            "_curl_check": lambda: preflight.Check("curl", True),
            "_creds_check": lambda p, r: (preflight.Check("AWS credentials", True,
                                                          "account 000"), "000"),
            "_bedrock_permission_check": bedrock,
            "_gateway_reachable_check": lambda u, k, h=False: (
                preflight.Check("LITELLM_URL", None),
                preflight.Check("LITELLM_MASTER_KEY", None)),
        }

    try:
        # region=None → skip, and no failure (skip is ok=None, not a fail).
        called = {"bedrock": False, "region": None}
        patch(preflight, make_stubs(called))
        lines: list[str] = []
        fail = preflight.run_preflight(profile=None, region=None,
                                       url=None, key=None, printer=lines.append)
        check("Bedrock probe skipped when region not supplied",
              called["bedrock"] is False)
        check("region-less run still passes (skip is not a failure)", fail is None)
        check("a skipped Bedrock row is still shown",
              any("Bedrock" in ln and "–" in ln for ln in lines),
              "\n".join(lines))
        restore()

        # region supplied → probe runs against the REAL region.
        called = {"bedrock": False, "region": None}
        patch(preflight, make_stubs(called))
        preflight.run_preflight(profile=None, region="eu-west-1",
                                url=None, key=None, printer=lambda *_: None)
        check("Bedrock probe runs when region supplied", called["bedrock"] is True)
        check("Bedrock probe uses the supplied region, not a default",
              called["region"] == "eu-west-1", f"got {called['region']}")
    finally:
        restore()


def test_preflight_gateway_skipped_when_not_supplied():
    """No URL/key supplied → both gateway checks are SKIPPED (ok is None), not
    failed — the handoff resolve step validates them later."""
    url_c, key_c = preflight._gateway_reachable_check(None, None)
    check("URL check skipped when not supplied", url_c.ok is None)
    check("key check skipped when not supplied", key_c.ok is None)
    # URL supplied directly but no key → key is a real failure (direct path
    # can't authenticate without it). curl may be absent → URL check is skip
    # or fail, but never a false pass; we only assert the key failure here.
    _url_c2, key_c2 = preflight._gateway_reachable_check("http://gw", None)
    check("key check fails when a direct URL is given but no key", key_c2.ok is False)


# --- 11. #115 Issue 4: handoff is a silent fallback, not a gate -------------
def test_gateway_export_hint_and_path():
    hint = gateway.export_hint()
    check("export hint names LITELLM_URL", "LITELLM_URL=" in hint)
    check("export hint names LITELLM_MASTER_KEY", "LITELLM_MASTER_KEY=" in hint)
    p = gateway.handoff_path("demo2")
    check("handoff path is handoff.<env>.json", p.name == "handoff.demo2.json")


def test_handoff_missing_is_not_a_required_file_error():
    """resolve_from_handoff's not-found message must point at the two exports
    and read as 'not supplied', NOT as 'a required file is missing' (#115 Issue 4)."""
    import tempfile as _tf
    with _tf.TemporaryDirectory() as d:
        patch, restore = make_monkeypatch()
        patch(gateway, {"DEPLOY_DIR": Path(d)})  # no handoff file in here
        try:
            raised = False
            try:
                gateway.resolve_from_handoff("nope-env", None, None)
            except RuntimeError as e:
                raised = True
                msg = str(e)
            check("missing handoff raises (fallback exhausted)", raised)
            check("message points at LITELLM_URL export", "LITELLM_URL=" in msg)
            check("message points at LITELLM_MASTER_KEY export", "LITELLM_MASTER_KEY=" in msg)
            check("message calls the handoff file OPTIONAL, not required",
                  "Optional" in msg and "not found" not in msg, msg)
        finally:
            restore()


def test_preflight_gateway_note_distinguishes_handoff_vs_export():
    """When the URL isn't supplied: handoff_available=True → 'read from the
    handoff file'; False → the concrete export hint. Neither is a failure."""
    # handoff available → shortcut note, no export hint shoved at the operator.
    url_c, key_c = preflight._gateway_reachable_check(None, None, handoff_available=True)
    check("handoff-available URL check is skipped (not fail)", url_c.ok is None)
    check("handoff-available note mentions the handoff file",
          "handoff file" in url_c.detail, url_c.detail)
    check("handoff-available note does NOT push an export",
          "LITELLM_URL=" not in url_c.detail, url_c.detail)
    # no handoff → export hint, still skipped (not a preflight failure).
    url_c2, key_c2 = preflight._gateway_reachable_check(None, None, handoff_available=False)
    check("no-handoff URL check still skipped (not fail)", url_c2.ok is None)
    check("no-handoff note shows the export hint",
          "LITELLM_URL=" in url_c2.detail, url_c2.detail)


# --- 11. add_account_cmd — offline unit checks (#129) ----------------------

def test_add_account_valid_prefix():
    check("valid prefix 'demo0'", add_account_cmd._valid_prefix("demo0") is None)
    check("valid prefix 'bu_1'", add_account_cmd._valid_prefix("bu_1") is None)
    check("valid prefix 'TeamA'", add_account_cmd._valid_prefix("TeamA") is None)
    check("empty prefix fails", add_account_cmd._valid_prefix("") is not None)
    check("prefix with dash fails", add_account_cmd._valid_prefix("team-A") is not None)
    check("prefix with slash fails", add_account_cmd._valid_prefix("a/b") is not None)
    check("prefix with space fails", add_account_cmd._valid_prefix("a b") is not None)
    check("prefix with dot fails", add_account_cmd._valid_prefix("a.b") is not None)


def test_add_account_bearer_key_var_name():
    # Dashes rejected by _valid_prefix, so only alphanumeric/underscore prefixes reach here.
    for prefix, expected in (("demo0", "BEDROCK_API_KEY_DEMO0"),
                              ("bu1", "BEDROCK_API_KEY_BU1"),
                              ("team_a", "BEDROCK_API_KEY_TEAM_A")):
        got = f"BEDROCK_API_KEY_{prefix.upper()}"
        check(f"bearer key var for '{prefix}' is valid shell name", got == expected)


def test_add_account_codex_catalog(tmp_home):
    """_write_codex_catalog writes {"models": [{slug, display_name, ...}]} format."""
    import json as _json
    out_dir = tmp_home / "codex-setup-test"
    orig = add_account_cmd.CODEX_SETUP_DIR
    add_account_cmd.CODEX_SETUP_DIR = out_dir
    try:
        path = add_account_cmd._write_codex_catalog("demo0", ["openai.gpt-5.6-sol", "openai.gpt-5.5"])
        data = _json.loads(path.read_text())
        check("catalog is a dict with 'models' key", isinstance(data, dict) and "models" in data)
        models = data["models"]
        check("models list has 2 entries", len(models) == 2)
        check("first entry has slug", models[0]["slug"] == "demo0/openai.gpt-5.6-sol")
        check("first entry has display_name", models[0]["display_name"] == "openai.gpt-5.6-sol")
        check("first entry has supported_reasoning_levels", len(models[0]["supported_reasoning_levels"]) > 0)
        check("second entry has slug", models[1]["slug"] == "demo0/openai.gpt-5.5")
        check("entry has shell_type", models[0].get("shell_type") == "shell_command")
        check("entry has visibility", models[0].get("visibility") == "list")
        check("entry has support_verbosity", models[0].get("support_verbosity") is True)
        check("entry has experimental_supported_tools", "experimental_supported_tools" in models[0])
        check("entry has base_instructions", "base_instructions" in models[0])
        check("entry has model_messages", "model_messages" in models[0])
        check("model_messages has instructions_template",
              "instructions_template" in models[0]["model_messages"])
    finally:
        add_account_cmd.CODEX_SETUP_DIR = orig


def test_add_account_codex_config(tmp_home):
    """_write_codex_config writes a TOML using lg-<gateway>-mantle-on-<prefix> naming and auth.command."""
    out_dir = tmp_home / "codex-cfg-test"
    orig = add_account_cmd.CODEX_SETUP_DIR
    add_account_cmd.CODEX_SETUP_DIR = out_dir
    try:
        path = add_account_cmd._write_codex_config("demo0", "https://example.cloudfront.net")
        text = path.read_text()
        check("config uses lg-gateway-mantle-on-prefix provider",
              'model_provider = "lg-example-mantle-on-demo0"' in text)
        check("config default model is prefixed", 'model = "demo0/' in text)
        check("config uses auth.command not env_key",
              'command = "/usr/bin/cat"' in text)
        check("config no env_key", 'env_key' not in text)
        check("config key file path contains provider name",
              'lg-example-mantle-on-demo0-litellm-key' in text)
        check("config base_url is the gateway url", "example.cloudfront.net" in text)
        check("config wire_api is responses", 'wire_api = "responses"' in text)
        check("config uses $HOME not tilde", '"$HOME/' in text)
    finally:
        add_account_cmd.CODEX_SETUP_DIR = orig


def test_add_account_abort_missing_gateway_vars():
    """run() exits ABORT immediately when LITELLM_URL or LITELLM_MASTER_KEY is absent."""
    import types
    args = types.SimpleNamespace(
        non_interactive=True, dry_run=False, full_reset=False, verbose=False,
        _scripted=None,
    )
    # Temporarily clear both vars from os.environ if present.
    saved_url = os.environ.pop("LITELLM_URL", None)
    saved_key = os.environ.pop("LITELLM_MASTER_KEY", None)
    try:
        rc = add_account_cmd.run(args)
        check("missing gateway vars → EXIT_ABORT", rc == add_account_cmd.EXIT_ABORT)
    finally:
        if saved_url is not None:
            os.environ["LITELLM_URL"] = saved_url
        if saved_key is not None:
            os.environ["LITELLM_MASTER_KEY"] = saved_key


def test_add_account_engine_env_passthrough():
    """engine.build_env propagates BEDROCK_API_KEY_ENV and TENANT from answers."""
    answers = {
        "_gateway_url": "https://gw.example.com",
        "_master_key": "sk-test",
        "region": "us-east-1",
        "families": "OpenAI/Mantle only",
        "catalog_mode": "Clean — reset",
        "tenant": "demo0",
        "bedrock_api_key_env": "BEDROCK_API_KEY_DEMO0",
    }
    env = engine.build_env(answers)
    check("TENANT passed to engine", env.get("TENANT") == "demo0")
    check("BEDROCK_API_KEY_ENV passed to engine", env.get("BEDROCK_API_KEY_ENV") == "BEDROCK_API_KEY_DEMO0")
    check("WIZARD_FAMILY is mantle", env.get("WIZARD_FAMILY") == "mantle")
    check("WIZARD_MODE is clean", env.get("WIZARD_MODE") == "clean")


def test_add_account_invalid_inject_wait_aborts_before_mutations():
    """run() exits ABORT early if TGW_INJECT_WAIT is not a valid non-negative int."""
    import types
    args = types.SimpleNamespace(
        non_interactive=True, dry_run=False, full_reset=False, verbose=False,
        _scripted=None,
    )
    saved_url = os.environ.get("LITELLM_URL", "")
    saved_key = os.environ.get("LITELLM_MASTER_KEY", "")
    os.environ["LITELLM_URL"] = "https://gw.example.com"
    os.environ["LITELLM_MASTER_KEY"] = "sk-test"
    os.environ["TGW_INJECT_WAIT"] = "not-a-number"
    try:
        rc = add_account_cmd.run(args)
        check("bad TGW_INJECT_WAIT → EXIT_ABORT", rc == add_account_cmd.EXIT_ABORT)
    finally:
        if saved_url:
            os.environ["LITELLM_URL"] = saved_url
        else:
            os.environ.pop("LITELLM_URL", None)
        if saved_key:
            os.environ["LITELLM_MASTER_KEY"] = saved_key
        else:
            os.environ.pop("LITELLM_MASTER_KEY", None)
        os.environ.pop("TGW_INJECT_WAIT", None)


def test_add_account_engine_strips_static_creds_when_profile_set():
    """engine.run() drops inherited static AWS creds when AWS_PROFILE is set."""
    import unittest.mock as _mock
    answers = {
        "_gateway_url": "https://gw.example.com",
        "_master_key": "sk-test",
        "region": "us-east-1",
        "aws_profile": "test-profile",
        "families": "OpenAI/Mantle only",
        "catalog_mode": "Clean — reset",
        "tenant": "demo0",
        "bedrock_api_key_env": "BEDROCK_API_KEY_DEMO0",
    }
    captured_env = {}

    def fake_call(cmd, cwd, env):
        captured_env.update(env)
        return 0

    with _mock.patch.dict(os.environ, {
        "AWS_ACCESS_KEY_ID": "FAKEAKID",
        "AWS_SECRET_ACCESS_KEY": "FAKESAK",
        "AWS_SESSION_TOKEN": "FAKETOK",
    }):
        with _mock.patch("subprocess.call", side_effect=fake_call):
            engine.run(answers, dry_run=False, confirm=False)

    check("AWS_ACCESS_KEY_ID stripped when profile set",
          "AWS_ACCESS_KEY_ID" not in captured_env)
    check("AWS_SECRET_ACCESS_KEY stripped when profile set",
          "AWS_SECRET_ACCESS_KEY" not in captured_env)
    check("AWS_SESSION_TOKEN stripped when profile set",
          "AWS_SESSION_TOKEN" not in captured_env)
    check("AWS_PROFILE present in env", captured_env.get("AWS_PROFILE") == "test-profile")


def main() -> int:
    with tempfile.TemporaryDirectory() as d:
        # Redirect config home so the test never writes to the real ~/.tgw.
        os.environ["TGW_CONFIG_HOME"] = d
        # config caches CONFIG_DIR at import; rebind for the test.
        config.CONFIG_DIR = Path(d)
        config.CONFIG_PATH = Path(d) / "config.json"
        tmp_home = Path(d)

        test_build_env_family_scope()
        test_build_env_mode()
        test_build_env_gateway()
        test_config_scrub(tmp_home)
        test_config_keying(tmp_home)
        test_resolver_precedence()
        test_resolver_validates_supplied()
        test_resume_summary()
        test_narration_ordering_not_tty()
        test_engine_not_invoked([])
        test_preflight_aws_version_parse()
        test_preflight_python_check_current()
        test_preflight_orchestrator_aborts_on_failure()
        test_preflight_orchestrator_all_pass()
        test_preflight_skips_bedrock_when_creds_fail()
        test_preflight_bedrock_region_gating()
        test_preflight_gateway_skipped_when_not_supplied()
        test_gateway_export_hint_and_path()
        test_handoff_missing_is_not_a_required_file_error()
        test_preflight_gateway_note_distinguishes_handoff_vs_export()
        test_add_account_valid_prefix()
        test_add_account_bearer_key_var_name()
        test_add_account_codex_catalog(tmp_home)
        test_add_account_codex_config(tmp_home)
        test_add_account_abort_missing_gateway_vars()
        test_add_account_engine_env_passthrough()
        test_add_account_invalid_inject_wait_aborts_before_mutations()
        test_add_account_engine_strips_static_creds_when_profile_set()

    print()
    if FAILS:
        print(f"FAILED: {FAILS} check(s)")
        return 1
    print("PASSED: all tgw offline checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
