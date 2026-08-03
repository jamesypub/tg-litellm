# deploy/ — LiteLLM AWS deployment (repeatable, profile-driven)

Deploys the LiteLLM gateway using the official BerriAI Terraform module pinned
at `v1.89.2` — ECS Fargate + Aurora PostgreSQL + ElastiCache Redis + ALB, in one
namespace per environment.

## Model

- **Profile-driven:** the target account is whatever `AWS_PROFILE` points at.
  Nothing hardcodes an account number.
- **Per-env isolation:** each environment uses `<env>.tfvars` **and** a Terraform
  **workspace** named `<env>`, so state never collides.
- **Namespace:** every resource is named `{tenant}-litellm-{env}` and tagged
  `litellm:stack=<that>`. Find resources by that prefix or tag (see below).
- **Restricted ingress:** every environment must set `alb_ingress_cidrs`.
  `deploy.sh` reconciles the upstream module's public rules after every apply.
  Direct `terraform apply` is unsupported; see issue #4.

## Files

Grouped by role. **When** tells you how each file runs: *declarative* (Terraform,
never run by hand), *entry point*, *auto* (chained by `deploy.sh … install`, but
also runnable standalone), *manual* (operator runs on demand), *sourced* (a shared
library, not executed), or *config*. The cron-refresher files carry their own
timing words — *setup-once* (prepared once, not executed), *manual once, then
cron* (run by hand once to mint the first token, then a scheduler drives it), and
*wrapper-invoked* (called only by another script, never by hand).

### Terraform — declarative; you don't run these directly
`deploy.sh` wraps `terraform`; direct `terraform apply` is unsupported (see #4).

| File | Purpose |
|---|---|
| `main.tf` | Calls the pinned BerriAI module (`v1.89.2`); declares outputs. Codex on by default — installer auto-mints the Bedrock API key (#61) |
| `variables.tf` | The core/shared input variables (incl. `codex_key_mode`, `enable_codex`) + validation. Feature-local inputs are declared next to their feature — CloudFront vars in `cloudfront.tf`, refresher vars in `codex-key-refresher.tf` |
| `versions.tf` | Provider + Terraform version pins |
| `cloudfront.tf` | CloudFront distribution in front of the ALB |
| `codex-secret.tf` | Secrets Manager secret holding the Codex/Mantle `BEDROCK_API_KEY`; skipped when a BYO key ARN is supplied (#79) |
| `codex-key-refresher.tf` | The built-in **Lambda** refresher + EventBridge schedule that re-mints the ~12h Bedrock key (`codex_key_mode = lambda_auto_refresh`, the default) |
| `.terraform.lock.hcl` | Provider dependency lock (committed; pinned for security, #26) |

### Entry point

| File | When | Purpose |
|---|---|---|
| `deploy.sh` | entry point | `AWS_PROFILE=… ./deploy.sh "$ENV" [plan\|apply\|install\|destroy]`. `install` chains preflight→apply→grant→register→verify fail-closed |

### Install-time helpers — `deploy.sh … install` runs these for you
Each is also runnable standalone (useful after a manual `apply`, or to re-run one step).

| File | When | Purpose |
|---|---|---|
| `preflight.sh` | auto | Fail-closed checks before apply (tfvars sanity, Codex key-mode consistency, #76) |
| `grant-bedrock.sh` | auto | Attaches the Bedrock invoke policy to the gateway task role (the module doesn't). **Mandatory** after a manual apply |
| `register-models.sh` | auto | Registers the Claude/Codex model set on the running gateway (also has a clean-slate wizard mode, #95) |
| `restrict-ingress.sh` | auto | Two modes (picked from the `cloudfront_enabled` output). CloudFront on: locks the ALB SG to CloudFront's origin-facing prefix list **and** associates WAF→ALB (moved out of TF, #12). CloudFront off: restricts the ALB SG to `alb_ingress_cidrs` (no WAF step) |
| `verify.sh` | auto | Post-deploy smoke test; exercises the Codex route when `enable_codex=true` (degrades not-ready to a warning, #72) |

### Codex / Mantle — only when `enable_codex = true`

| File | When | Purpose |
|---|---|---|
| `make-codex-catalog.sh` | auto (via `render-handoff.sh`) | Generates a version-matched Codex catalog entry (needs the `codex` CLI). The normal path is automatic — `render-handoff.sh` calls it when building a developer package; runnable standalone only to regenerate the entry by hand |

#### `codex-key-refresher/` — only when `codex_key_mode = external_cron_auto_refresh`
The **no-Lambda** cron fallback for orgs whose SCP blocks `lambda:CreateFunction`
(#84). Nothing here runs during `install`; you wire it up once, then cron drives
it. See [../docs/codex-cron-key-refresh.md](../docs/codex-cron-key-refresh.md).

| File | When | Purpose |
|---|---|---|
| `refresh-codex-key.env.sample` | setup-once | Template → copy to `refresh-codex-key.env` and fill in (`REGION`, `SECRET_ARN`, `ECS_CLUSTER`, `ECS_SERVICE`, `CRED_MODE`). Not auto-ignored — keep your filled copy out of git yourself (it holds your account's ARNs) |
| `refresh-codex-key.sh` | manual once, then cron | The wrapper. Run it **once by hand** during setup to mint+store the first token (per the cron guide), then schedule it on cron (e.g. every 6h) to re-mint before expiry. Loads the env (exported vars win over the file), then execs the `.py` |
| `refresh-codex-key.py` | wrapper-invoked | The actual refresher: mints a fresh ~12h Bedrock key, stores it in the secret, rolls the ECS service. Invoked by the `.sh` wrapper — never called directly |

### Operator / handoff

| File | When | Purpose |
|---|---|---|
| `render-handoff.sh` | manual | Renders a per-developer config package from admin-created team/keys (#51) |
| `seed-test-data.sh` | manual | Populates **throwaway** teams/users/keys and runs real Claude+Codex calls to check spend tracking. Separate from install — never run against production data |
| `check-claude-managed-settings.sh` | manual | Detects an enterprise Claude Code MANAGED-settings policy that conflicts with LiteLLM token auth (#39); safe to ship in a rendered package |
| `lib.sh` | sourced | Shared bash helpers sourced by the other scripts — not executed directly |

### Config

| File | When | Purpose |
|---|---|---|
| `env.tfvars.example` | config | Template → copy to `$ENV.tfvars`: `tenant`/`env`, size, TLS choice, `enable_codex`, `codex_key_mode` |
| `$ENV.tfvars` | config | Your per-env config (git-ignored; never committed) |

## Usage

Set the profile + env once, then commands are copy/paste-safe (no `<ANGLE>`
placeholders — `<`/`>` are shell redirection operators):

```bash
export AWS_PROFILE="customer-admin"    # profile picks the account
export ENV="prod"

./deploy.sh "$ENV" install             # one-command, fail-closed: preflight→apply→grant→register→verify
# or run the stages yourself:
./deploy.sh "$ENV" plan
./deploy.sh "$ENV" apply
./grant-bedrock.sh "$ENV"              # REQUIRED after a manual apply
./deploy.sh "$ENV" destroy
```

To add another environment/account: copy `env.tfvars.example` → `$ENV.tfvars`
(change `tenant`/`env` and `alb_ingress_cidrs`), then set `AWS_PROFILE` + `ENV`
for that account and run `./deploy.sh "$ENV" install`.

## Find installed resources

```bash
# by tag (across services)
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=litellm:stack,Values=$TENANT-litellm-$ENV" \
  --query 'ResourceTagMappingList[].ResourceARN' --output table
# or from state ($ENV as exported above; $TENANT is your tfvars tenant)
terraform workspace select "$ENV" && terraform state list && terraform output
```

## Post-apply steps

The one-command `./deploy.sh "$ENV" install` does all of these fail-closed. If you
ran `apply` manually instead:

1. `./grant-bedrock.sh "$ENV"` — grant Bedrock to the task role (**mandatory**).
2. Get master key: `aws secretsmanager get-secret-value --secret-id "$(terraform output -raw master_key_secret_arn)" --query SecretString --output text`.
3. Register models (see [installer.md](../docs/installer.md) step 6).
4. Codex/Mantle (only if `enable_codex = true`): the installer auto-mints the
   short-lived (~12h) `BEDROCK_API_KEY`. Rotation is governed by `codex_key_mode`
   (the front-door over the older `enable_codex_key_refresh` flag, #76):
   `lambda_auto_refresh` (default — a built-in Lambda re-mints it; you configure
   nothing) or `external_cron_auto_refresh` (for orgs whose SCP blocks Lambda —
   run the cron yourself, see [../docs/codex-cron-key-refresh.md](../docs/codex-cron-key-refresh.md)).
5. Open the admin UI, create org/team/user/keys, render each developer a config
   package (see [../docs/admin.md](../docs/admin.md)); developers paste it
   (see [../docs/client-setup.md](../docs/client-setup.md)).

> **Migrations run automatically.** The database bootstrap and Prisma migrations
> run as a one-off ECS task **during `apply`** — you do **not** run them by hand.
> The `migration_run_command` terraform output is a **break-glass** command to
> *re-run* the migration task if ever needed, not a required install step.

## Notes

- `db_instance_class = db.t4g.medium` is the Aurora PostgreSQL floor (smaller
  classes aren't valid for Aurora).
  that broke the AWS Go SDK INI parser used by Terraform.
- The module's default `db_engine_version = 16.4` is **not offered** for
  aurora-postgresql in us-east-1. We override to `16.13` (valid: 16.8/9/10/11/13).
  Check `aws rds describe-db-engine-versions --engine aurora-postgresql` per region.
- **Module version ≠ LiteLLM software version.** The module (pinned `v1.89.2`)
  defaults the container images to an older `-dev` tag (`v1.86.0-dev`). We pin the
  software via `image_tag` (default `v1.92.0`, latest stable) → the module's
  `gateway_image`/`backend_image`/`ui_image`/`migrations_image`. Bump `image_tag`
  in `<env>.tfvars` to upgrade LiteLLM. Verify the tag exists as split images
  (litellm-gateway/backend/ui/migrations) in ghcr.io/berriai before pinning.
