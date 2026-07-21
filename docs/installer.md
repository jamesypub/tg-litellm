# Installer Guide — tg-llmgateway on AWS

The one ordered path to install the gateway into **your own AWS account and
Bedrock region**. It uses only documented prerequisites and inputs — clone the
repo and follow this guide plus the example tfvars, nothing else.

This guide is **variable-based**: you export a few shell variables once, then
every command below is copy/paste-safe (no `<ANGLE>` placeholders — in shell `<`
and `>` are redirection operators, so a pasted `<GATEWAY_URL>` would error). The
target account is whatever `AWS_PROFILE` points at; the region comes from your
tfvars (single source of truth). Every helper prints the account, region, env, and
workspace before it acts, and refuses to run against the wrong workspace.

Set these once (used by every step):

```bash
export AWS_PROFILE="customer-admin"     # selects the AWS account
export ENV="prod"                       # environment name = tfvars + TF workspace
```

---

## Quick start vs. production hardening

This guide's **quick-start** path gets a working gateway up fast. It is a real,
usable deployment — apply the **production-hardening** deltas below before (or right
after) going live:

| | Quick start | Production hardening |
|---|---|---|
| ALB | HTTP allowed (`allow_plaintext_alb=true`) | HTTPS via ACM cert (`allow_plaintext_alb=false`) or CloudFront edge TLS |
| Gateway tasks | 1 | ≥2 (HA) |
| Pricing | LiteLLM defaults + approximate Codex pin | verify rates for billing |
| Terraform state | local (owner-only; see note) | encrypted remote backend (see note) |
| Network | IP allowlist or CloudFront origin lock | restricted ingress + WAF |

> **Terraform state holds plaintext secrets** (master key, DB/UI passwords,
> CloudFront origin secret) — Terraform's `sensitive` flag hides them from CLI
> output but does **not** encrypt state at rest. The quick-start path uses local
> state; the installer keeps `$ENV.tfvars` and all `terraform.tfstate*` files
> owner-only (`0600`) and refuses to run if they're group/world-readable. **For
> production**, use a remote backend with: encryption at rest (S3 SSE-KMS), state
> locking (DynamoDB or S3 lockfile), object versioning, and least-privilege bucket
> access.

---

## Prerequisites

- **Terraform** ≥ 1.5, **AWS CLI v2**, `python3`, `curl`.
- AWS identity that can create VPC, ECS, RDS, ElastiCache, IAM, Secrets Manager,
  ALB (Administrator is simplest).
- **Bedrock model access enabled** in your region (Console → Bedrock → Model
  access) for the Claude / OpenAI models you'll use.
- Two AZs in your region.
- *(Production)* an ACM certificate + domain for HTTPS.

---

## Steps

### 1. Confirm identity
```bash
aws sts get-caller-identity          # confirm account + identity ($AWS_PROFILE)
```

### 2. Copy and edit an environment tfvars
```bash
git clone https://github.com/jamesypub/tg-litellm.git && cd tg-litellm/deploy
cp env.tfvars.example "$ENV.tfvars"
```
Set in `$ENV.tfvars`: `region`, `tenant` (name prefix), `env` (= `$ENV`),
`azs` (two), `ui_password`, and `alb_ingress_cidrs` (authorized workstation or
VPN IPv4 CIDRs). For HTTPS set `acm_certificate_arn` and
`allow_plaintext_alb = false`; for the quick-start path leave the cert empty and set
`allow_plaintext_alb = true` (or use CloudFront edge TLS — see below). `enable_codex`
defaults to `true` (Claude + Codex; the installer mints the Codex key automatically,
step 5) — set it `false` for Claude-only. Models are **not**
listed here — the installer registers them. (`region` in this file is the source
of truth for every helper.)

### 3. Install (one command, fail-closed)
```bash
./deploy.sh "$ENV" install     # preflight → apply → grant-bedrock → register → verify
```
`install` runs **preflight automatically first**, then applies infrastructure,
grants Bedrock, registers models, checks the serving model registry, and verifies
the enabled routes. **It fails nonzero if any required stage fails** and never
prints "Install complete" on a partial install. **Database bootstrap and Prisma
migrations run automatically** during apply — do not run migrations by hand (the
`migration_run_command` output is a break-glass re-run only). On success it writes
non-secret `handoff.$ENV.json` for the administrator.

> Step-by-step equivalent (if you prefer to run the stages yourself):
> ```bash
> ./deploy.sh "$ENV" preflight    # tools, identity, region, tfvars, AZs, TLS, Codex config
> ./deploy.sh "$ENV" plan         # review the change set
> ./deploy.sh "$ENV" apply        # create infra (~10–15 min; Aurora is slow)
> ```
> then steps 4–6 below. The one-command `install` is the supported path.

### 4. Grant Bedrock permissions (only if running stages manually)
```bash
./grant-bedrock.sh "$ENV"       # attaches bedrock:Invoke*/Converse* to the gateway task role
```
Required — the module does not grant Bedrock by default. The policy is scoped to
this account/region's `foundation-model/*` and `inference-profile/*` ARNs (not
`Resource=*`); set `BEDROCK_RESOURCES` (comma-separated ARNs) to narrow it to
specific models.

### 5. Codex works out of the box — nothing to configure
Codex/gpt-5.x is on by default, alongside Claude. `install` mints the Bedrock API
key the Codex route needs, stores it in Secrets Manager, and a built-in Lambda
rotates it automatically. You create no secret and set no ARN.

For a Claude-only gateway, set `enable_codex = false`. To use a Bedrock API key you
manage yourself instead of the minted one, set its ARN in
`gateway_extra_secrets.BEDROCK_API_KEY` (see the example tfvars).

### 6. Register models (only if running stages manually)
```bash
GATEWAY_URL="$(terraform output -raw cloudfront_url 2>/dev/null || terraform output -raw alb_url)"
MK="$(aws secretsmanager get-secret-value \
       --secret-id "$(terraform output -raw master_key_secret_arn)" \
       --query SecretString --output text)"
# ENV="$ENV" makes region come from $ENV.tfvars (the source of truth)
ENV="$ENV" LITELLM_URL="$GATEWAY_URL" LITELLM_MASTER_KEY="$MK" ./register-models.sh
```
Registers each Claude inference profile under its **exact `inferenceProfileId`** as
the canonical name (e.g. `global.anthropic.claude-opus-4-8`; cross-account:
`<TENANT>/<inferenceProfileId>`) **and** the friendly `global/`/`us/` scope-prefixed
alias additively (both route to the same profile). Also registers gpt-oss,
and reachable Codex models, and registers them — using LiteLLM's built-in prices,
pinning only Codex from LiteLLM's own `bedrock_mantle/` price entry. It reports
any discovery gaps and exits non-zero if the model set is incomplete.

**Cross-account tenant:** to register models that run in a *different* Bedrock
account, you must pass `DISCOVER_PROFILE` (creds that can list models there) plus
`BEDROCK_ROLE_ARN`/`BEDROCK_EXTERNAL_ID`; there is no silent fallback. See
`register-models.sh` header.

### 7. Review ingress / enable HTTPS
Confirm `$ENV.tfvars` contains only the intended `alb_ingress_cidrs`.
The deployment wrapper rejects public IPv4 `/0` ingress and reconciles the ALB
after each apply. Always use `deploy.sh`; direct `terraform apply` bypasses this
interim safeguard (tracked in issue #4).

For HTTPS, set `acm_certificate_arn` + `allow_plaintext_alb=false` and re-run
`./deploy.sh "$ENV" apply`.

### 8. Post-install verification (only if running stages manually)
```bash
./verify.sh "$ENV"      # health, model listing, Claude via Messages, Codex via Responses (if enabled)
```
Claude must pass (task-role SigV4). When `enable_codex = true`, the Codex Responses
route must also pass — a failed Codex call fails verification. When `enable_codex`
is not true, Codex is skipped cleanly.

### 9. Hand off to the administrator
The installer writes non-secret `deploy/handoff.$ENV.json` (environment name,
gateway/admin URLs, registered model aliases, supported client versions, and
Secrets Manager references — **no** key/password values). Give the administrator:
- **Admin UI:** the `admin_url` from `handoff.$ENV.json`
- **Admin login:** `admin` / your `ui_password`
- **Master key:** in Secrets Manager (the `master_key_secret_arn` from the handoff)

The admin creates per-user virtual keys with budgets, then renders each developer
a complete config package with the handoff renderer (see
[admin.md](admin.md)); developers just paste it (see
[client-setup.md](client-setup.md)).

---

## Codex behavior (recorded on v1.92.0)

Codex/gpt-5.x usage capture **and** hard budget caps **work** on the pinned image,
provided the route has a price (step 6 handles this). Caveats: the Bedrock API key
is refreshed automatically (~12h TTL) when `enable_codex_key_refresh = true`, and
cap enforcement is eventually-consistent (~40s after a cap change).

## Remove everything
```bash
./deploy.sh "$ENV" destroy
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Model calls AccessDenied | run `./grant-bedrock.sh "$ENV"` |
| Aurora engine version error | set a valid `db_engine_version` in tfvars |
| Gateway unreachable | check ingress allowlist / that you're on an allowed IP |
| Codex `invalid_api_key` | refresh the Bedrock API key (step 5) |
| register-models exits non-zero | read its WARNING lines — model set is incomplete |
| `API Error: Connection closed mid-response` / stream cut on a long turn | idle/stream timeout — see the streaming FAQ below |

## FAQ

### "Connection closed mid-response" / the stream drops on long turns

**Symptom.** A CLI (Claude Code / Codex) request fails partway through with
`API Error: Connection closed mid-response` (or the stream just cuts), usually
right after a long "thinking" pause with no visible output.

**Cause.** When you enable CloudFront (`enable_cloudfront = true`), the edge and the
ALB each enforce an **inter-packet (idle) timeout** — the maximum time allowed
*between streamed bytes*, not the total request time. A long model thinking gap
sends no bytes, so if the gap exceeds the idle timeout the connection is closed
mid-stream. It is not a model, key, or repo problem; a short request to the same
model succeeds.

**What the installer does.** The default `cloudfront_origin_read_timeout` is
**60 seconds** — CloudFront's universal default, which applies under **any** AWS
account without a quota change. `deploy.sh` reconciles the ALB idle timeout to
match. 60s is safe to apply everywhere but will still cut a thinking pause longer
than 60s.

**To tolerate longer pauses (recommended for heavy agent use):** you can raise the
value. The CloudFront **"Response timeout per origin"** quota defaults to **120s**,
so `cloudfront_origin_read_timeout` can be set up to **120 with no approval**:

```bash
# in $ENV.tfvars — up to 120 needs no quota change
cloudfront_origin_read_timeout = 120
```
then `./deploy.sh "$ENV" apply` (a CloudFront-only update; it does not restart the
gateway).

**To go up to 180**, request a Service Quotas increase for CloudFront → "Response
timeout per origin" (AWS console → Service Quotas, or
`aws service-quotas request-service-quota-increase --service-code cloudfront
--quota-code L-AECE9FA7 --desired-value <N>`). **180s is the account-level hard
cap** (AWS-confirmed) — requests above 180 through Service Quotas are rejected, so
don't ask for more than 180 this way.

**To go above 180 (up to 540)**, open an AWS Support case for a per-distribution
increase: give your CloudFront **Distribution ID** and a written use case. An
internal team evaluates it case by case — it's not self-service and not guaranteed.

Setting a value above your account's current quota makes `apply` fail with
`InvalidOriginReadTimeout`, so only raise the tfvars value after the increase is
actually granted.

**If a single no-output pause can exceed your raised value**, or you can't get the
quota, run without CloudFront (`enable_cloudfront = false`) and use the
IP-allowlist + ACM/HTTPS posture, where the ALB idle timeout is the only hop to
size (it is not subject to the CloudFront quota).

**Note.** LiteLLM (pinned image) does not emit SSE keep-alive/heartbeat bytes to
keep an idle stream warm, so raising the idle timeout is the supported mitigation
today rather than a keep-alive setting.

### What TLS minimum does the edge enforce? (default vs. custom certificate)

With the **default** CloudFront certificate (`*.cloudfront.net`, no custom
domain), CloudFront **cannot enforce a TLS 1.2+ viewer minimum** — it pins the
viewer minimum to its platform default regardless of what you declare, so the
installer does **not** declare an (ineffective) minimum on this path (#49). This
avoids a false "TLS 1.2 enforced" claim and perpetual Terraform plan drift.

To actually enforce **TLS 1.2+ at the viewer**, use a **custom certificate**:
set `cloudfront_acm_certificate_arn` (a **us-east-1** ACM cert) and
`cloudfront_aliases` (your domain name(s)) in `$ENV.tfvars`, then apply. With a
custom cert, `minimum_protocol_version = TLSv1.2_2021` is applied and verifiable
from the live AWS API. The ALB-only (no-CloudFront) posture uses your ACM cert on
the listener directly.

### Which model name do I give Claude Code vs. Codex?

Use the **exact client-facing alias** your admin's rendered package sets — do not
guess. A model that works in a raw `/v1/messages` curl can still be rejected by the
Claude Code CLI if the alias form differs; the admin renderer selects a
client-compatible alias for you. See [client-setup.md](client-setup.md).
