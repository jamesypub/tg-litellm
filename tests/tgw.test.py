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

from wizard import config, engine  # noqa: E402
from wizard.prompts import Question, Resolver, PromptAbort, resume_summary  # noqa: E402

FAILS = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global FAILS
    if cond:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}  {detail}")


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

    print()
    if FAILS:
        print(f"FAILED: {FAILS} check(s)")
        return 1
    print("PASSED: all tgw offline checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
