# How to install Codex and activate it on a developer laptop

This is the end-to-end path for turning on **Codex / gpt-5.x** on an
already-deployed gateway and getting a developer's Codex CLI talking to it. It
ties together the three docs you need and answers the question that trips
everyone up: *where does the Bedrock API key come from?*

There are two halves:

1. **Operator / infra** — enable Codex on the gateway and keep its short-term
   Bedrock key rotated.
2. **Developer laptop** — paste the admin-rendered Codex package and launch.

---

## Part 1 — Operator: enable Codex on the gateway

Codex authenticates to Bedrock **Mantle** with a **short-term Bedrock API key**
(~12h TTL). You have two ways to keep that key fresh:

| Path | Use when | Doc |
|---|---|---|
| **Built-in Lambda** (default) | Your org allows `lambda:CreateFunction`. Zero manual steps — the installer mints the key and a Lambda rotates it. | [installer.md](installer.md) step 5 |
| **Self-hosted cron** | Your org's SCP **blocks** `lambda:CreateFunction`. You run the re-mint yourself on a host cron. | **[codex-cron-key-refresh.md](codex-cron-key-refresh.md)** |

If you're on the default path, enabling Codex is just `enable_codex = true` in
tfvars and a re-apply — nothing else. If you're on the no-Lambda cron path,
follow [codex-cron-key-refresh.md](codex-cron-key-refresh.md) end to end (secret,
script, IAM, tfvars, apply, crontab, verify).

> Unsure whether your org allows the Lambda? Check with
> `aws iam simulate-principal-policy --policy-source-arn "$(aws sts get-caller-identity --query Arn --output text)" --action-names lambda:CreateFunction --query 'EvaluationResults[0].EvalDecision' --output text` —
> `allowed` → default path; a deny → cron path.

### FAQ: "Where does the `BEDROCK_API_KEY` come from?"

The single most common question. Short answer: **you mint it — it isn't fetched
from anywhere.**

- There is **no** AWS console page for it and **no** `aws bedrock create-api-key`
  command. The Bedrock API key is a **bearer token derived from your own AWS
  credentials** (SigV4-presign a `CallWithBearerToken` request, base64 it). The
  refresher script does exactly this.
- Don't conflate the two objects:
  - the **secret** = the Secrets Manager *container* (an ARN). You create it once
    with `aws secretsmanager create-secret`. Empty at first.
  - the **token** = the *value* inside it. Minted by the refresher script; rotated
    on the Lambda (default) or your cron (no-Lambda path).
- On the **default** path you never see this — the installer mints the first
  token and the Lambda owns rotation. You only deal with `BEDROCK_API_KEY`
  directly on the **cron / bring-your-own** path, where the ARN you put in
  `gateway_extra_secrets` points the gateway at *your* secret.

### FAQ: "`install` vs `apply` — which do I run to add Codex?"

Use **`apply`** when you're bringing your own key (cron path):
`./deploy.sh <env> apply`. Do **not** run `install` on that path — `install`
auto-mints a token into the *Terraform-owned* secret and would **overwrite your
bring-your-own key**.

### FAQ: "Does the cron/refresher host need to reach the gateway's VPC?"

**No.** The refresher only calls AWS API endpoints — `bedrock.amazonaws.com`,
Secrets Manager, and ECS. It needs outbound HTTPS to those plus the IAM policy in
[codex-cron-key-refresh.md](codex-cron-key-refresh.md) — **not** VPC peering or a
route into the gateway's subnets. If someone is trying to join the refresher box
to the litellm VPC to make key rotation work, that's unnecessary.

### FAQ: "Codex verify says 'not ready' — did the install fail?"

No. If the Codex Responses route reports not-ready (e.g. region Mantle access is
still enabling), that's a **warning**, not a failure — Claude still serves and
the install passes. Only a route that is configured + reachable but *erroring*
fails closed. See [installer.md](installer.md) step 8 and the region prerequisite
FAQ.

---

## Part 2 — Developer laptop: activate Codex CLI

Nothing here requires the developer to touch AWS or keys directly — the admin
renders them a **Codex package** and they paste it. Full detail in
[client-setup.md](client-setup.md); the shape:

1. **Admin renders the package** (one per developer, per env) — see
   [admin.md](admin.md). This creates the virtual key with a budget and emits a
   paste-able package containing the gateway URL, the key, the allowed Codex
   models, and a named profile.

   ```bash
   AWS_PROFILE="$AWS_PROFILE" ./deploy/render-handoff.sh "$ENV" codex dev-alice-codex \
     --create 50 openai.gpt-5.6-sol --user alice
   ```

2. **Developer pastes the package.** It writes an owner-only key file, a named
   profile `~/.codex/<env>.config.toml` (with the exact canonical model and
   `wire_api = "responses"`), the model catalog, and a launcher.

3. **Launch:**
   ```bash
   codex-lg-<env>
   ```

Key points for the developer (from [client-setup.md](client-setup.md)):

- `wire_api = "responses"` — Codex talks to the gateway's `/v1/responses`.
- The `model` must be the **exact canonical Mantle ID** the admin set
  (e.g. `openai.gpt-5.6-sol`); `codex /model` lists the compatible models the key
  allows.
- Claude Code and Codex use **separate keys/aliases** — a Codex package does not
  cover Claude Code and vice versa.

---

## Quick reference — which doc for what

| I want to… | Go to |
|---|---|
| Enable Codex the normal (Lambda) way | [installer.md](installer.md) step 5 |
| Run the key refresh myself (no-Lambda org) | [codex-cron-key-refresh.md](codex-cron-key-refresh.md) |
| Create a developer's Codex key + package | [admin.md](admin.md) |
| Set up Codex CLI on a laptop | [client-setup.md](client-setup.md) |
