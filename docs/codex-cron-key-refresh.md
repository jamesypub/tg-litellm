# Codex Bedrock key — self-hosted cron refresh (no-Lambda orgs)

Codex / gpt-5.x on this gateway authenticates to Bedrock **Mantle** with a
**short-term Bedrock API key** (a bearer token, ~12h TTL). The default install
deploys a small **Lambda** that re-mints this token automatically before it
expires. If your organization's SCP denies `lambda:CreateFunction`, that Lambda
cannot be created — so you run the same re-mint yourself on a schedule (a host
cron), writing the fresh token into the **Secrets Manager secret the gateway
reads**.

This guide covers that path end to end. Claude is unaffected either way (it uses
task-role SigV4, no bearer token). For the whole Codex picture — enabling it,
this cron path, and activating it on a developer laptop — see
[codex-install-and-activate.md](codex-install-and-activate.md).

> **Status:** verified end-to-end on staging as of v1.1 — a retained
> bring-your-own-key environment applies cleanly (no secret collision, no clobber),
> the key rotates, and the Codex `/v1/responses` route returns 200 against the BYO
> secret. Supported on **v1.1 and later** (the `codex_key_mode` selector does not
> exist on v1.0).

---

## When to use this

Use the cron path **only** if your org blocks the Lambda refresher — i.e. an SCP
denies `lambda:CreateFunction`, so the default built-in-Lambda refresher can't be
created. If Lambda is allowed, prefer the default (built-in Lambda) — you
configure nothing.

> If you're unsure whether your org allows it, check before applying:
> ```bash
> aws iam simulate-principal-policy \
>   --policy-source-arn "$(aws sts get-caller-identity --query Arn --output text)" \
>   --action-names lambda:CreateFunction \
>   --query 'EvaluationResults[0].EvalDecision' --output text
> ```
> `allowed` → use the default Lambda path. `explicitDeny`/`implicitDeny` → use
> this cron path.

---

## Overview

Each run of the refresher does exactly what the built-in Lambda does, minus the
Lambda:

1. **Mint** a fresh short-term Bedrock API key from the caller's own AWS
   credentials (SigV4-presign a `CallWithBearerToken` request, base64 it).
2. **Write** it into the `BEDROCK_API_KEY` Secrets Manager secret the gateway
   reads.
3. **Roll** the gateway ECS service (`force-new-deployment`) so it picks up the
   rotated value.

Run it every 6 hours — half the ~12h TTL, so a single missed run still leaves a
valid token.

---

## Where does the Bedrock API key come from?

This is the most common point of confusion, so it's worth stating plainly:

- **You do not fetch it from anywhere.** There is no AWS console page for it and
  no `aws bedrock create-api-key` CLI command. The Bedrock API key is a **bearer
  token you *mint* from your own AWS credentials** — by SigV4-presigning a
  `CallWithBearerToken` request and base64-encoding the result. The
  `refresh-codex-key.py` script in step 4 *is* the thing that produces it.
- Two separate objects, don't conflate them:
  - **The secret** (the Secrets Manager *container*, identified by an ARN) — you
    create this once with `aws secretsmanager create-secret` (step 1). It's empty
    at first.
  - **The token** (the *value* stored in that secret) — the refresher script mints
    it and writes it in. The very first token comes from running that script once;
    the cron then re-mints it every 6h before the ~12h expiry.

So the flow is: create the (empty) secret → run the script once to mint+store the
first token → put the secret's ARN in tfvars → schedule the script on cron.

## 1. Create the secret (once)

The gateway reads the token from a Secrets Manager secret you own. Create it and
seed it with a first token (the cron only *rotates* an existing secret; the
gateway needs a valid value at first apply).

```bash
export AWS_PROFILE="customer-admin"
export REGION="us-east-1"                 # your Bedrock region

# Create the (empty) secret and capture its ARN.
export BAK_ARN="$(aws secretsmanager create-secret \
  --name tg-codex-bedrock-key \
  --region "$REGION" \
  --query ARN --output text)"
echo "$BAK_ARN"
```

Mint and store the first token by running the script below once (step 3), or
inline now. Keep `$BAK_ARN` — it goes in your tfvars.

---

## 2. Configure tfvars

In `$ENV.tfvars`, select the no-Lambda refresh process and point the gateway at
your secret:

```hcl
enable_codex   = true
codex_key_mode = "external_cron_auto_refresh"   # Terraform deploys NO refresher; your cron re-mints the key
gateway_extra_secrets = {
  BEDROCK_API_KEY = "arn:aws:secretsmanager:us-east-1:<acct>:secret:tg-codex-bedrock-key-XXXXXX"
}
```

- `codex_key_mode = "external_cron_auto_refresh"` — the front-door choice: no
  built-in Lambda is created; you own key rotation via the cron in this guide. (It
  derives `enable_codex_key_refresh = false`; you don't set that flag directly.)
- `gateway_extra_secrets.BEDROCK_API_KEY` — points the gateway at *your* secret,
  used verbatim. This takes precedence over the TF-owned secret.

> **Version note:** `codex_key_mode` is a **v1.1** setting. On v1.0 this mode does
> not exist and `enable_codex = true` forces the built-in Lambda — the no-Lambda
> path is not available. Deploy from v1.1 (or later) for this procedure.

---

## 3. Apply — use `apply`, not `install`

```bash
AWS_PROFILE="$AWS_PROFILE" ./deploy.sh "$ENV" apply
./grant-bedrock.sh "$ENV"
# register models + verify (see docs/installer.md steps 6 & 8)
```

> **Do not run `deploy.sh <env> install` on this path.** `install` auto-mints a
> fresh short-term token into the **Terraform-owned** secret — which would
> **clobber your bring-your-own key**. The `apply` + manual-steps path leaves your
> secret untouched.

---

## 4. The refresher script

Save as `refresh-codex-key.py`. It imports `boto3`/`botocore` and adds no other
third-party dependencies, but those two are still a real prerequisite: the
`python3` that cron runs must be able to import them. AWS CLI v2 does **not**
satisfy this — it ships its own bundled runtime, so a host with only `awscli`
and a bare `python3` fails with `ModuleNotFoundError` before the first token is
minted (#83). Most current distros mark the system `python3` as an
externally-managed environment (PEP 668), so `pip install --user` into it fails
closed with an error rather than installing anything — use an owner-only venv
instead, and point the wrapper at that venv's interpreter specifically:

```bash
/usr/bin/python3 -m venv "$HOME/.tg-litellm/venv"
"$HOME/.tg-litellm/venv/bin/python3" -m pip install --quiet boto3 botocore
# fail-closed preflight against the EXACT interpreter the wrapper will exec:
"$HOME/.tg-litellm/venv/bin/python3" -c "import boto3, botocore" \
  || { echo "MISSING: boto3/botocore not importable in $HOME/.tg-litellm/venv" >&2; exit 1; }
```

The script replicates the built-in Lambda's algorithm exactly — a
SigV4-QUERY-presigned `CallWithBearerToken` POST with a 12h expiry, base64'd,
with the `bedrock-api-key-` prefix.

```python
#!/usr/bin/env python3
import base64, os, sys, time, boto3
from datetime import datetime, timezone
from botocore.auth import SigV4QueryAuth
from botocore.awsrequest import AWSRequest

HOST = "bedrock.amazonaws.com"
URL = f"https://{HOST}/"
SERVICE = "bedrock"
PREFIX = "bedrock-api-key-"
VERSION = "&Version=1"
TTL = 43200  # 12h
WAIT_DELAY = 15
WAIT_MAX_ATTEMPTS = 40  # 10-min ceiling on the ECS stability wait

def progress(msg):
    # Timestamped phase/heartbeat line on STDERR (stdout stays the one success
    # line). Run by hand, the ECS wait below is silent for minutes and looks hung.
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{ts}  {msg}", file=sys.stderr, flush=True)

def mint_token(region):
    creds = boto3.Session().get_credentials().get_frozen_credentials()
    req = AWSRequest(method="POST", url=URL, headers={"host": HOST},
                     params={"Action": "CallWithBearerToken"})
    SigV4QueryAuth(creds, SERVICE, region, expires=TTL).add_auth(req)
    presigned = req.url.replace("https://", "") + VERSION
    return PREFIX + base64.b64encode(presigned.encode()).decode()

def is_stable(ecs, cluster, service):
    # Rollout complete: exactly one deployment, running == desired (same success
    # condition as the services_stable waiter — we poll it to emit heartbeats).
    svc = ecs.describe_services(cluster=cluster, services=[service])["services"][0]
    d = svc["deployments"]
    return len(d) == 1 and d[0]["runningCount"] == d[0]["desiredCount"]

def main():
    region  = os.environ["REGION"]
    secret  = os.environ["SECRET_ARN"]
    cluster = os.environ["ECS_CLUSTER"]        # e.g. <tenant>-litellm-<env>
    service = os.environ["ECS_SERVICE"]        # e.g. <tenant>-litellm-<env>-gateway

    progress("minting Bedrock bearer token…")
    token = mint_token(region)

    boto3.client("secretsmanager", region_name=region).put_secret_value(
        SecretId=secret, SecretString=token)
    progress("rotated key → stored in Secrets Manager")

    ecs = boto3.client("ecs", region_name=region)
    progress(f"updating ECS service {service} (force new deployment)…")
    ecs.update_service(cluster=cluster, service=service, forceNewDeployment=True)

    # ECS injects the secret as an env var at task START and never re-reads it, so
    # the fresh key is served only after the rolled task reaches steady state. Poll
    # for it, heartbeating each cycle, and print success ONLY then; fail on timeout.
    # Printing before the roll is stable leaves the old task (old key) serving
    # traffic -> 401 'token expired'.
    ceiling = WAIT_DELAY * WAIT_MAX_ATTEMPTS
    progress(f"waiting for ECS to reach steady state (up to {ceiling}s)…")
    start = time.monotonic()
    for attempt in range(1, WAIT_MAX_ATTEMPTS + 1):
        if is_stable(ecs, cluster, service):
            break
        if attempt == WAIT_MAX_ATTEMPTS:
            raise SystemExit(
                f"{service} did not reach steady state within "
                f"{ceiling}s; token stored but roll unconfirmed")
        time.sleep(WAIT_DELAY)
        progress(f"still waiting… ({int(time.monotonic() - start)}s elapsed)")

    progress(f"ECS update complete — {service} (stable)")
    print(f"rotated Codex key and rolled {service} (stable)")

if __name__ == "__main__":
    main()
```

Wire it with a wrapper `refresh-codex-key.sh` so cron has the environment:

```bash
#!/usr/bin/env bash
set -euo pipefail
export REGION="us-east-1"
export SECRET_ARN="arn:aws:secretsmanager:us-east-1:<acct>:secret:tg-codex-bedrock-key-XXXXXX"
export ECS_CLUSTER="<tenant>-litellm-<env>"
export ECS_SERVICE="<tenant>-litellm-<env>-gateway"
# AWS creds via instance role (preferred) or AWS_PROFILE/keys in the environment.
PYTHON="$HOME/.tg-litellm/venv/bin/python3"
# Fail closed BEFORE minting if this interpreter can't import the deps (#83) —
# must be the exact venv interpreter the exec line below uses.
"$PYTHON" -c "import boto3, botocore" \
  || { echo "refresh-codex-key: $PYTHON missing boto3/botocore (see section 4 venv setup)" >&2; exit 1; }
exec "$PYTHON" /opt/tg-litellm/refresh-codex-key.py
```

Run it once by hand to seed the first token and confirm it works:

```bash
./refresh-codex-key.sh
```

---

## 5. IAM — permissions the cron principal needs

The host/role running the cron mints a token that authorizes **as this
principal**, so it needs the same Bedrock rights the token will be used for, plus
write-secret and roll-service:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "MintBedrockToken",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:Converse",
        "bedrock:ConverseStream"
      ],
      "Resource": "*"
    },
    {
      "Sid": "MantleInvoke",
      "Effect": "Allow",
      "Action": [
        "bedrock-mantle:CallWithBearerToken",
        "bedrock-mantle:CreateInference"
      ],
      "Resource": "*"
    },
    {
      "Sid": "WriteSecret",
      "Effect": "Allow",
      "Action": ["secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"],
      "Resource": "arn:aws:secretsmanager:us-east-1:<acct>:secret:tg-codex-bedrock-key-*"
    },
    {
      "Sid": "RollGateway",
      "Effect": "Allow",
      "Action": ["ecs:UpdateService", "ecs:DescribeServices", "ecs:ListServices"],
      "Resource": "*"
    }
  ]
}
```

Prefer an **EC2 instance role** carrying this policy over long-lived access keys.

> **Connectivity note.** The refresher host does **not** need to join or peer with
> the gateway's VPC. It only calls **AWS API endpoints** — `bedrock.amazonaws.com`,
> Secrets Manager, and ECS — so it needs outbound HTTPS to those (public endpoints,
> or VPC interface endpoints if egress is locked down) and the IAM above. VPC
> reachability to the gateway itself is not required for key rotation.

---

## 6. Schedule it

Every 6 hours. Two things matter here (#82):

- **Log to an owner-writable path, not `/var/log`.** A *user* crontab runs as
  that user, and `/var/log` is root-owned — the `>>` redirect fails there before
  the wrapper even runs, so a rotation can silently never happen and the ~12h key
  expires. Write under `$HOME` instead.
- **Pre-create the log file `0600` before installing the crontab.** `umask 077`
  in *this* install shell only governs files *this shell* creates — cron invokes
  the job in its own separate shell later, and if the log doesn't exist yet,
  that shell's `>>` redirect creates it under cron's own umask (commonly `022`,
  giving a world-readable `0644` log; found live in a clean cron-like
  environment, #82). Creating the file here, before cron ever touches it, means
  the later `>>` only appends and never changes its mode.
- **Install one uniquely-marked entry idempotently**, so re-running setup doesn't
  stack duplicate cron lines.

```bash
mkdir -p "$HOME/.tg-litellm"
umask 077   # log may echo timestamps only, but keep it owner-only regardless

LOG="$HOME/.tg-litellm/refresh.log"
touch "$LOG" && chmod 600 "$LOG"
[ "$(stat -c%a "$LOG" 2>/dev/null || stat -f%Lp "$LOG")" = 600 ] || { echo "refresh.log is not 0600" >&2; exit 1; }

# Replace-in-place by a unique marker (no duplicate entries on rerun):
CRON_MARK="# tg-litellm-codex-refresh"
CRON_LINE="0 */6 * * * \$HOME/.tg-litellm/refresh-codex-key.sh >> \$HOME/.tg-litellm/refresh.log 2>&1  $CRON_MARK"
existing="$(crontab -l 2>/dev/null || true)"                       # tolerate "no crontab yet"
printf '%s\n%s\n' "$(printf '%s\n' "$existing" | grep -vF "$CRON_MARK" || true)" "$CRON_LINE" \
  | sed '/^$/d' | crontab -
crontab -l | grep -F "$CRON_MARK"                                  # confirm the single entry
```

> If you prefer a **system** cron (root), drop a file in `/etc/cron.d/` instead —
> then `/var/log` is writable and the marker/idempotency still apply. Pick one
> path; don't mix a user crontab with a root log target.

---

## 7. Verify

```bash
# Token is present and freshly rotated:
aws secretsmanager describe-secret --secret-id "$SECRET_ARN" \
  --query 'LastChangedDate' --output text

# Value has the expected prefix (do not log the whole token):
aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
  --query 'SecretString' --output text | cut -c1-16

# Gateway rolled and Codex route answers:
./verify.sh "$ENV"     # exercises the Codex Responses route when enable_codex=true
```

If Codex reports **not ready** (region Mantle access still enabling), that is a
warning, not a failure — Claude still serves. See `docs/installer.md` for the
region/Mantle prerequisite.
