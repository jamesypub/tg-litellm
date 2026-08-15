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

> **Connectivity note (primary account refresher).** The primary refresher
> (`refresh-codex-key.sh`) only calls **AWS API endpoints** — `bedrock.amazonaws.com`,
> Secrets Manager, and ECS — so it needs outbound HTTPS to those (public endpoints,
> or VPC interface endpoints if egress is locked down). Direct network reachability
> to the gateway itself is **not** required for the primary refresher.
>
> **Secondary account refresher** (`refresh-mantle-account.sh`) additionally POSTs
> to the gateway's `/config/update` endpoint to inject the fresh key into the
> running LiteLLM process. That host **must** be able to reach the gateway's HTTPS
> URL (CloudFront or ALB) — ensure the cron host's IP is in `alb_ingress_cidrs` or
> that CloudFront is enabled.

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

### 6a. Secondary account refresh (if you used `tgw add-account`)

If you onboarded a second AWS account with `tgw add-account`, its bearer token also
expires in ~12h and needs its own cron refresh. The secondary refresher
(`refresh-mantle-account.sh`) writes to **both** Secrets Manager and the gateway's
live config (via `/config/update`, no ECS restart). The primary refresher owns the
single ECS restart — schedule secondary first, primary 3 minutes later.

**Run this once per secondary account** (substitute your actual prefix for `<PREFIX>`,
e.g. `demo0`):

```bash
PREFIX=<PREFIX>   # e.g. demo0 — must match the prefix used with tgw add-account
# Gateway account ID and region — the secret is created HERE, not in the secondary account:
GW_REGION=<gateway-region>         # e.g. us-east-1
GW_ACCOUNT_PROFILE=<gateway-aws-profile>  # profile with access to the gateway account

mkdir -p "$HOME/.tg-litellm"
umask 077

# Create log file 0600 before cron touches it:
touch "$HOME/.tg-litellm/refresh-${PREFIX}.log"
chmod 600 "$HOME/.tg-litellm/refresh-${PREFIX}.log"

# Create the Secrets Manager secret to hold this account's bearer token
# in the GATEWAY account and region (not the secondary account).
# tgw add-account does NOT create this secret — it only injects the initial
# token into the gateway's running config via /config/update.
PREFIX_UPPER="$(echo "$PREFIX" | tr '[:lower:]' '[:upper:]')"
SECRET_ARN="$(AWS_PROFILE="$GW_ACCOUNT_PROFILE" aws secretsmanager create-secret \
  --region "$GW_REGION" \
  --name "BEDROCK_API_KEY_${PREFIX_UPPER}" \
  --description "${PREFIX} Bedrock bearer key (rotated by cron)" \
  --secret-string placeholder \
  --query ARN --output text)"
echo "Created secret: $SECRET_ARN"

# Install BOTH scripts (shell wrapper + Python worker) — skip if already installed:
if [ ! -f "$HOME/.tg-litellm/refresh-mantle-account.sh" ]; then
  cp deploy/codex-key-refresher/refresh-mantle-account.sh "$HOME/.tg-litellm/refresh-mantle-account.sh"
  cp deploy/codex-key-refresher/refresh-mantle-account.py "$HOME/.tg-litellm/refresh-mantle-account.py"
  chmod 700 "$HOME/.tg-litellm/refresh-mantle-account.sh"
fi
# Python requirements — use the shared venv created in §4 (PEP 668 safe):
if [ ! -d "$HOME/.tg-litellm/venv" ]; then
  /usr/bin/python3 -m venv "$HOME/.tg-litellm/venv"
fi
"$HOME/.tg-litellm/venv/bin/python3" -m pip install --quiet boto3 botocore
"$HOME/.tg-litellm/venv/bin/python3" -c "import boto3, botocore" \
  || { echo "MISSING: boto3/botocore not importable in venv" >&2; exit 1; }

# Create a per-prefix env file (never overwrites an existing configured file):
ENV_FILE="$HOME/.tg-litellm/refresh-${PREFIX}-mantle-account.env"
if [ ! -f "$ENV_FILE" ]; then
  cp deploy/codex-key-refresher/refresh-mantle-account.env.sample "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Created $ENV_FILE — edit it before running cron."
else
  echo "$ENV_FILE already exists — not overwriting."
fi
# Edit $ENV_FILE: fill in REGION=$GW_REGION, SECRET_ARN=<from above>,
#   LITELLM_URL, LITELLM_MASTER_KEY, BEDROCK_API_KEY_ENV=BEDROCK_API_KEY_${PREFIX_UPPER},
#   CRED_MODE=profile, AWS_PROFILE=<secondary-account-profile>, UPDATE_ECS=false

# Create a per-prefix cron wrapper that sources the right env file, applies
# CRED_MODE credential isolation, and calls the Python worker via the venv.
# Each account gets its own wrapper so cron entries are fully independent:
WRAPPER="$HOME/.tg-litellm/refresh-${PREFIX}-mantle.sh"
cat > "$WRAPPER" <<WRAPPER_EOF
#!/usr/bin/env bash
# Auto-generated per-prefix wrapper for prefix=${PREFIX}.
# Do not edit; re-run the §6a setup block to regenerate.
set -euo pipefail
umask 077
. "${HOME}/.tg-litellm/refresh-${PREFIX}-mantle-account.env"
export REGION SECRET_ARN LITELLM_URL LITELLM_MASTER_KEY BEDROCK_API_KEY_ENV UPDATE_ECS
[ "\${UPDATE_ECS:-false}" = "true" ] && export ECS_CLUSTER ECS_SERVICE
# CRED_MODE isolation — mirrors the logic in refresh-mantle-account.sh:
case "\${CRED_MODE:-profile}" in
  instance_role) unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN ;;
  profile)
    [ -n "\${AWS_PROFILE:-}" ] || { echo "CRED_MODE=profile requires AWS_PROFILE" >&2; exit 1; }
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    export AWS_PROFILE ;;
esac
exec "${HOME}/.tg-litellm/venv/bin/python3" "${HOME}/.tg-litellm/refresh-mantle-account.py"
WRAPPER_EOF
chmod 700 "$WRAPPER"

# Add BOTH cron entries (secondary first, primary 3 min later):
CRON_MARK2="# tg-litellm-mantle-refresh-${PREFIX}"
CRON_LINE2="0 */6 * * * $HOME/.tg-litellm/refresh-${PREFIX}-mantle.sh >> $HOME/.tg-litellm/refresh-${PREFIX}.log 2>&1  $CRON_MARK2"
CRON_MARK="# tg-litellm-codex-refresh"
CRON_LINE="3 */6 * * * $HOME/.tg-litellm/refresh-codex-key.sh >> $HOME/.tg-litellm/refresh.log 2>&1  $CRON_MARK"
existing="$(crontab -l 2>/dev/null || true)"
printf '%s\n%s\n%s\n' \
  "$(printf '%s\n' "$existing" | grep -vF "$CRON_MARK2" | grep -vF "$CRON_MARK" || true)" \
  "$CRON_LINE2" "$CRON_LINE" | sed '/^$/d' | crontab -
crontab -l | grep -E "tg-litellm"    # confirm both entries
```

> If you have multiple secondary accounts, repeat this block with a different `PREFIX`
> each time. Each account gets its own env file, log file, per-prefix wrapper, and cron
> marker — no shared state between accounts. The `refresh-mantle-account.sh`, `.py`, and
> venv are shared and installed only once.

**Required additional IAM** for the secondary account cron principal (beyond §5):

```json
{
  "Sid": "WriteSecondaryTokenSecret",
  "Effect": "Allow",
  "Action": [
    "secretsmanager:PutSecretValue",
    "secretsmanager:DescribeSecret"
  ],
  "Resource": "arn:aws:secretsmanager:<region>:<gateway-account>:secret:BEDROCK_API_KEY_<PREFIX>*"
}
```

> The cron principal must be able to write the token secret in the **gateway account**
> (where Secrets Manager stores it). If the cron runs in the secondary account and the
> secret lives in the gateway account, attach a resource-based policy to the secret
> granting `PutSecretValue`/`DescribeSecret` to the secondary cron identity cross-account.
>
> The refresher also POSTs to the gateway's HTTPS URL using `LITELLM_MASTER_KEY` — no
> extra IAM is needed for that call, but keep `refresh-mantle-account.env` at `0600`.

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

## 8. Token lifetime & session duration

The bearer key is a SigV4 **presigned URL** minted with a 12-hour expiry
(`X-Amz-Expires=43200`). **A presign cannot outlive the credentials that signed
it** — so a "12h" token only lasts 12h if the *signing session* actually lasts
~12h. This is the trap behind #120: the signing role's `MaxSessionDuration` was
raised to 12h, yet tokens still died at ~1h, because the credential *request*
defaulted to 1 hour. How you fix it depends on `CRED_MODE`.

### `CRED_MODE=profile` — a named `~/.aws/config` profile signs (guaranteed 12h)

**Two levers, both required:**

1. The signing role's **`MaxSessionDuration = 43200`** (raise it in IAM if lower).
2. **`duration_seconds = 43200` on the profile** the cron uses. This is the one
   people miss — raising only `MaxSessionDuration` leaves the request at the 1h
   default, so the vended session (and the token) still dies at ~1h.

Minimum profile — add to `~/.aws/config` for the identity the cron runs as
(replace every `<...>`; this is the shape proven on demo2):

```ini
[profile lg_dev]
role_arn          = arn:aws:iam::<ACCOUNT_ID>:role/<SIGNING_ROLE_NAME>
credential_source = Ec2InstanceMetadata   # chain off the host instance role (no static keys)
role_session_name = codex-key-refresher
region            = us-east-1
duration_seconds  = 43200                 # REQUEST a 12h session — the #120 lever
```

| Field | Purpose | Notes |
|---|---|---|
| `role_arn` | role assumed to sign the token | its `MaxSessionDuration` must be `>= 43200` |
| `credential_source = Ec2InstanceMetadata` | bootstrap the assume from the host instance role — no keys on disk | instance role must be trusted to assume `role_arn` |
| `role_session_name` | session label | any stable string |
| `region` | STS + Bedrock + gateway region | match the deployment |
| `duration_seconds = 43200` | **request** a 12h session | without it the assume defaults to 1h even when the role allows more (the #120 bug) |

Do **not** add `aws_access_key_id` / `aws_secret_access_key` — the point is no
static keys; creds come from the instance role via `credential_source`.

Then point the refresher at it in `refresh-codex-key.env`:

```ini
CRED_MODE=profile
AWS_PROFILE=lg_dev
```

> **A bare profile alone does nothing.** In `instance_role` mode the wrapper
> *unsets* `AWS_PROFILE` and all `AWS_*` (so a leaked identity can't sign), and
> `profile` mode fails closed unless `AWS_PROFILE` is set. "Create a profile" and
> "set `CRED_MODE=profile` + `AWS_PROFILE`" go together.

**Verify — measure, don't trust:**

```bash
aws configure export-credentials --profile lg_dev --format process \
  | python3 -c "import sys,json;print('Expiration:',json.load(sys.stdin)['Expiration'])"
# Expiration ~12h out → good. ~1h out → duration_seconds missing, or the role's
# MaxSessionDuration < 43200. Fix that, not just MaxSessionDuration.
```

### `CRED_MODE=instance_role` — the host EC2 instance role signs (NO profile)

This is the "the machine just has the role, no AWS profile" setup (the
`.env.sample` default). Here **there is no `duration_seconds` knob**: the creds
are the IMDS instance-role session, whose lifetime is governed by EC2/IMDS
auto-rotation, not a per-call duration — you cannot extend it with any profile
setting.

If you need a **guaranteed** ~12h token, use `profile` mode above (a role that
permits 12h + `duration_seconds`). Otherwise, confirm the **actual** vended
session length on your instance and keep the cron cadence well under it:

```bash
# On the instance, read how long the current instance-role session is valid:
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
ROLE=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/)
curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE" \
  | python3 -c "import sys,json;print('Expiration:',json.load(sys.stdin)['Expiration'])"
```

If that lifetime is shorter than your cron cadence needs, either switch to
`profile` mode or tighten the cadence. (If the instance role instead **chains**
to a second role via `credential_source=Ec2InstanceMetadata`, that reduces to the
`profile` case and both levers apply.)

See #120 for the live root-cause analysis.

> **Troubleshooting — token expires ~1h after mint despite 12h presign:**
> This is `profile` mode with no `duration_seconds` set. The STS session defaults
> to 1h; the presign can't outlive it. Fix: add `duration_seconds = 43200` to the
> profile in `~/.aws/config` **and** confirm the role's `MaxSessionDuration` allows
> it (`aws iam get-role --role-name <role> --query 'Role.MaxSessionDuration'` →
> must be `>= 43200`). In `instance_role` mode this symptom does not apply — EC2
> manages session renewal automatically.

---

## 9. Is the Lambda refresher enabled? (and how to switch)

Use this when you need to confirm which refresh path is active, or switch between
the Lambda (default) and cron (this doc's) paths.

```bash
# --- Config (fill in before running) ----------------------------------------
TENANT="${TENANT:?set TENANT}"
ENV="${ENV:?set ENV}"
REGION="${REGION:-us-east-1}"
FN="${TENANT}-litellm-${ENV}-codex-key-refresher"

echo "=== 1. Is the Lambda path permitted by your org SCP? ==="
DECISION="$(aws iam simulate-principal-policy \
  --policy-source-arn "$(aws sts get-caller-identity --query Arn --output text)" \
  --action-names lambda:CreateFunction \
  --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null || echo unknown)"
echo "  lambda:CreateFunction -> $DECISION"
# allowed -> Lambda path available; explicitDeny/implicitDeny -> use cron path

echo "=== 2. Is the Lambda refresher deployed for $TENANT/$ENV? ==="
if aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  STATE="$(aws scheduler get-schedule --name "$FN" --region "$REGION" \
           --query 'State' --output text 2>/dev/null || echo NONE)"
  echo "  function present, schedule state: $STATE"
else
  echo "  function NOT deployed — you are on the cron path"
fi
```

**To switch modes**, set `codex_key_mode` in your `env.tfvars`:

```hcl
codex_key_mode = "lambda_auto_refresh"          # Lambda manages refresh (default)
# codex_key_mode = "external_cron_auto_refresh" # cron manages refresh (this doc's path)
```

Then `terraform apply` (via `deploy.sh "$ENV" apply`). The variable is defined in
`deploy/variables.tf`.
