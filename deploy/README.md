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

| File | Purpose |
|---|---|
| `main.tf` | Calls the pinned BerriAI module; declares outputs |
| `variables.tf` / `versions.tf` | Inputs + provider (region from `var.region`) |
| `$ENV.tfvars` | per-env config (from `env.tfvars.example`): `tenant`/`env`, size, TLS choice, `enable_codex` |
| `deploy.sh` | `AWS_PROFILE=… ./deploy.sh "$ENV" [plan\|apply\|install\|destroy]` |
| `grant-bedrock.sh` | Attaches Bedrock invoke policy to the gateway task role (module doesn't) |

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
4. Codex/Mantle (only if `enable_codex = true`): provide `BEDROCK_API_KEY`
   (short-lived, ~12h) + set `enable_codex_key_refresh = true`.
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
