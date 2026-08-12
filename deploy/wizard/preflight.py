"""Read-only preflight — prerequisites BEFORE any question (spec §4 phase 1, #115 Issue 3).

Nothing here mutates anything. Each check is a small read-only probe that
returns a Check result; `run_preflight()` prints a clear ✓/✗ line per item and
returns the first failure (if any) so the caller can abort *before* asking a
single question. This is the fix for the customer-silent failure where an old
AWS CLI's error text bled into the wizard's stdin mid-run (#115 Issue 3).

Checks whose input isn't known yet (e.g. the gateway URL that a handoff file
resolves only after questions) are reported as SKIPPED, not failed — the later
resolve step still validates them.
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass

MIN_PYTHON = (3, 8)
MIN_AWS_CLI = (2, 15, 0)   # list-inference-profiles requires AWS CLI v2.15+


@dataclass
class Check:
    """One preflight line. ok=True pass, ok=False fail, ok=None skipped."""
    label: str          # what was checked, shown after the mark
    ok: bool | None
    detail: str = ""    # extra context appended to the label (version, account…)
    hint: str = ""      # multi-line fix hint, printed only when ok is False


def check_python() -> str | None:
    """Return an error message if the interpreter is too old, else None.

    Kept as a standalone string-returning helper for callers that check the
    interpreter before anything else (the interpreter running THIS code).
    """
    if sys.version_info < MIN_PYTHON:
        want = ".".join(str(n) for n in MIN_PYTHON)
        have = ".".join(str(n) for n in sys.version_info[:3])
        return f"Python {want}+ is required (found {have})."
    return None


def _python_check() -> Check:
    have = ".".join(str(n) for n in sys.version_info[:3])
    err = check_python()
    if err:
        return Check("python3", False, have,
                     "install a newer Python 3 (3.8+) and re-run.")
    return Check("python3", True, have)


def _parse_aws_version(text: str) -> tuple[int, ...] | None:
    """Pull the (major, minor, patch) out of `aws --version` output.

    Example first token: `aws-cli/2.17.0 Python/3.11 ...`. Returns None if the
    string doesn't look like AWS CLI v2 output.
    """
    m = re.search(r"aws-cli/(\d+)\.(\d+)\.(\d+)", text)
    if not m:
        return None
    return tuple(int(g) for g in m.groups())


_AWS_UPGRADE_HINT = (
    "Mac:   brew upgrade awscli\n"
    "    Linux: curl \"https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip\" "
    "-o /tmp/awscliv2.zip \\\n"
    "             && unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install --update"
)


def _aws_cli_check() -> Check:
    if shutil.which("aws") is None:
        return Check("aws CLI", False, "not found on PATH",
                     "install AWS CLI v2 (v2.15+):\n    " + _AWS_UPGRADE_HINT)
    try:
        out = subprocess.run(["aws", "--version"], capture_output=True,
                             text=True, timeout=30)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return Check("aws CLI", False, "could not run `aws --version`",
                     "install AWS CLI v2 (v2.15+):\n    " + _AWS_UPGRADE_HINT)
    # `aws --version` prints to stdout on v2, stderr on some builds — check both.
    ver = _parse_aws_version((out.stdout or "") + (out.stderr or ""))
    if ver is None:
        return Check("aws CLI", False,
                     "AWS CLI v1 (or unrecognized) detected — v2.15+ required",
                     _AWS_UPGRADE_HINT)
    have = ".".join(str(n) for n in ver)
    if ver < MIN_AWS_CLI:
        want = ".".join(str(n) for n in MIN_AWS_CLI)
        return Check("aws CLI", False, f"{have} detected — v{want}+ required",
                     _AWS_UPGRADE_HINT)
    return Check("aws CLI", True, have)


def _curl_check() -> Check:
    if shutil.which("curl") is None:
        return Check("curl", False, "not found on PATH",
                     "install curl (Mac: preinstalled; Linux: `sudo apt-get install -y curl`).")
    return Check("curl", True)


def aws_identity(profile: str | None = None, region: str | None = None) -> dict:
    """Resolve the caller's AWS identity (read-only). Returns a dict with
    'account'/'arn' on success, or {'error': msg} on failure.
    """
    cmd = ["aws", "sts", "get-caller-identity", "--output", "json"]
    if profile:
        cmd += ["--profile", profile]
    if region:
        cmd += ["--region", region]
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30
        )
    except FileNotFoundError:
        return {"error": "the AWS CLI (`aws`) was not found on PATH."}
    except subprocess.TimeoutExpired:
        return {"error": "AWS identity check timed out after 30s."}
    if out.returncode != 0:
        stderr = (out.stderr or "").strip()
        return {"error": stderr or "could not resolve AWS credentials."}
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError:
        return {"error": "unexpected response from `aws sts get-caller-identity`."}
    return {"account": data.get("Account", ""), "arn": data.get("Arn", "")}


def _creds_check(profile: str | None, region: str | None) -> tuple[Check, str]:
    """Verify AWS creds resolve. Returns (Check, account_id) — account is ""
    on failure so callers don't render a bogus id."""
    ident = aws_identity(profile, region)
    if "error" in ident:
        return (
            Check("AWS credentials", False, ident["error"],
                  sso_login_hint(profile)),
            "",
        )
    return (
        Check("AWS credentials", True, f"account {ident['account']}"),
        ident["account"],
    )


def _bedrock_permission_check(profile: str | None, region: str) -> Check:
    """Confirm the caller can list inference profiles — the exact call the
    engine makes to discover Claude models. A permission/region failure here is
    the #95 abort the operator would otherwise hit mid-run."""
    cmd = [
        "aws", "bedrock", "list-inference-profiles",
        "--region", region, "--type-equals", "SYSTEM_DEFINED",
        "--output", "json",
    ]
    if profile:
        cmd += ["--profile", profile]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except FileNotFoundError:
        return Check("Bedrock list-inference-profiles", False,
                     "the AWS CLI (`aws`) was not found on PATH",
                     "install AWS CLI v2 (v2.15+) and re-run.")
    except subprocess.TimeoutExpired:
        return Check("Bedrock list-inference-profiles", False,
                     "timed out after 30s",
                     f"check network/VPC access to Bedrock in {region} and re-run.")
    if out.returncode != 0:
        err = (out.stderr or "").strip().splitlines()
        first = err[0] if err else "the call failed"
        return Check("Bedrock list-inference-profiles", False,
                     first,
                     "grant bedrock:ListInferenceProfiles (and confirm the region "
                     f"has Bedrock) — checked {region}.")
    return Check("Bedrock list-inference-profiles", True, f"region {region}")


def _gateway_reachable_check(
    url: str | None, key: str | None, handoff_available: bool = False,
) -> tuple[Check, Check]:
    """Two related checks: LITELLM_URL reachable, LITELLM_MASTER_KEY set.

    When the URL/key aren't supplied up-front they're SKIPPED, not failed —
    but the skip note distinguishes the two ways they can still be resolved
    (#115 Issue 4): a handoff.$ENV.json file (silent fallback) vs. neither, in
    which case the operator must export them (the note shows exactly how)."""
    from . import gateway  # local import to avoid a cycle at module load

    def _unsupplied_note() -> str:
        if handoff_available:
            return "not set — will be read from the handoff file"
        return ("not set — export it before proceeding:\n        "
                + gateway.export_hint().replace("\n", "\n        "))

    if not url:
        # Not a failure: a handoff file (or a later export) supplies it. But when
        # NEITHER is available we still don't fail preflight — the gateway
        # resolve step will, with the same export hint; here we just inform.
        url_check = Check("LITELLM_URL set + reachable", None, _unsupplied_note())
    elif shutil.which("curl") is None:
        url_check = Check("LITELLM_URL set + reachable", None,
                          "curl unavailable — skipping the reachability probe")
    else:
        probe = url.rstrip("/") + "/health/liveliness"
        try:
            out = subprocess.run(
                ["curl", "-sf", "-o", "/dev/null", "-w", "%{http_code}",
                 "--max-time", "15", probe],
                capture_output=True, text=True, timeout=30)
            code = (out.stdout or "").strip()
            if out.returncode == 0 and code.startswith("2"):
                url_check = Check("LITELLM_URL set + reachable", True, url)
            else:
                url_check = Check("LITELLM_URL set + reachable", False,
                                  f"{url} did not answer /health/liveliness"
                                  + (f" (HTTP {code})" if code else ""),
                                  "confirm the gateway URL is correct and the "
                                  "service is running, then re-run.")
        except subprocess.TimeoutExpired:
            url_check = Check("LITELLM_URL set + reachable", False,
                              f"{url} timed out",
                              "confirm the gateway is reachable from here and re-run.")

    if key:
        key_check = Check("LITELLM_MASTER_KEY set", True)
    elif url:
        # URL supplied directly but no key → the direct path can't authenticate,
        # and a handoff file can't fill just the key. This is a real failure.
        key_check = Check("LITELLM_MASTER_KEY set", False, "not set",
                          "export LITELLM_MASTER_KEY (the gateway admin key) and re-run.")
    else:
        key_check = Check("LITELLM_MASTER_KEY set", None, _unsupplied_note())
    return url_check, key_check


def sso_login_hint(profile: str | None) -> str:
    """The exact recovery line for expired/absent SSO creds (spec §5.4)."""
    p = f" --profile {profile}" if profile else ""
    return f"run `aws sso login{p}` (or refresh your credentials) and re-run."


def run_preflight(
    *,
    profile: str | None,
    region: str | None,
    url: str | None,
    key: str | None,
    handoff_available: bool = False,
    printer=print,
) -> Check | None:
    """Run every preflight check, print a ✓/✗ line per item, and return the
    FIRST failing Check (or None if all passed/skipped). The caller aborts on a
    non-None return BEFORE asking any question (#115 Issue 3).

    `region` may be None if the operator hasn't supplied one; the Bedrock check
    is then SKIPPED (not guessed against a default that could false-fail a
    different-region customer) — the engine re-validates it at discovery time.
    `handoff_available` tells the gateway-var lines whether a handoff.$ENV.json
    will silently supply the URL/key, so an absent env var reads as a shortcut
    rather than a missing requirement (#115 Issue 4).
    """
    printer("\n  Checking prerequisites…")

    checks: list[Check] = [
        _python_check(),
        _aws_cli_check(),
        _curl_check(),
    ]
    creds, _account = _creds_check(profile, region)
    checks.append(creds)
    # Only probe Bedrock if creds resolved — otherwise the error is redundant.
    if creds.ok:
        if region:
            # Region supplied up-front → probe the REAL region.
            checks.append(_bedrock_permission_check(profile, region))
        else:
            # No region yet (it's a Phase-2 question, asked after this preflight).
            # Probing the us-east-1 default would FALSE-FAIL a customer whose
            # Bedrock region differs, so skip rather than guess — the engine
            # re-validates list-inference-profiles against the chosen region at
            # discovery time (#115 Issue 3: preflight must precede every question,
            # so it can only probe a region known before the questions run).
            checks.append(Check(
                "Bedrock list-inference-profiles", None,
                "skipped — region not supplied yet (checked at discovery time); "
                "pass --region to probe it here"))
    url_check, key_check = _gateway_reachable_check(url, key, handoff_available)
    checks.extend([url_check, key_check])

    first_fail: Check | None = None
    for c in checks:
        mark = "✓" if c.ok else ("✗" if c.ok is False else "–")
        line = f"    {mark} {c.label}"
        if c.detail:
            line += f" — {c.detail}"
        printer(line)
        if c.ok is False and first_fail is None:
            first_fail = c

    if first_fail is None:
        printer("    → all checks passed.")
        return None

    printer("\n    → fix the above and re-run. Nothing was changed.")
    if first_fail.hint:
        for hline in first_fail.hint.splitlines():
            printer(f"      {hline}")
    return first_fail
