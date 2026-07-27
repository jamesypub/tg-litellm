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

Save as `refresh-codex-key.py`. It uses only `boto3`/`botocore` (no extra
dependencies) and replicates the built-in Lambda's algorithm exactly — a
SigV4-QUERY-presigned `CallWithBearerToken` POST with a 12h expiry, base64'd,
with the `bedrock-api-key-` prefix.

```python
#!/usr/bin/env python3
import base64, os, boto3
from botocore.auth import SigV4QueryAuth
from botocore.awsrequest import AWSRequest

HOST = "bedrock.amazonaws.com"
URL = f"https://{HOST}/"
SERVICE = "bedrock"
PREFIX = "bedrock-api-key-"
VERSION = "&Version=1"
TTL = 43200  # 12h

def mint_token(region):
    creds = boto3.Session().get_credentials().get_frozen_credentials()
    req = AWSRequest(method="POST", url=URL, headers={"host": HOST},
                     params={"Action": "CallWithBearerToken"})
    SigV4QueryAuth(creds, SERVICE, region, expires=TTL).add_auth(req)
    presigned = req.url.replace("https://", "") + VERSION
    return PREFIX + base64.b64encode(presigned.encode()).decode()

def main():
    region  = os.environ["REGION"]
    secret  = os.environ["SECRET_ARN"]
    cluster = os.environ["ECS_CLUSTER"]        # e.g. <tenant>-litellm-<env>
    service = os.environ["ECS_SERVICE"]        # e.g. <tenant>-litellm-<env>-gateway

    token = mint_token(region)

    boto3.client("secretsmanager", region_name=region).put_secret_value(
        SecretId=secret, SecretString=token)

    boto3.client("ecs", region_name=region).update_service(
        cluster=cluster, service=service, forceNewDeployment=True)

    print(f"rotated Codex key in {secret}; rolled {service}")

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
exec /usr/bin/python3 /opt/tg-litellm/refresh-codex-key.py
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

Every 6 hours (crontab on the host):

```cron
0 */6 * * * /opt/tg-litellm/refresh-codex-key.sh >> /var/log/codex-key-refresh.log 2>&1
```

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
