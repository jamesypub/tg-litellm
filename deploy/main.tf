# tg-llmgateway — LiteLLM AWS deployment (official BerriAI module, pinned).
# Namespace = {tenant}-litellm-{env}; find resources by that prefix or the
# tag litellm:stack=<name>. State is per-env (see deploy.sh backend/workspace).
module "litellm" {
  # Pinned to the immutable commit SHA that tag v1.89.2 resolved to (not the
  # mutable tag) so the module bytes can't change under a fixed ref (#26).
  # To upgrade: pick a new tag, resolve its commit, update this SHA in a PR.
  source = "github.com/BerriAI/litellm//terraform/litellm/aws?ref=94dae27b0c555d2549ee5077a16d6ea5542244bd" # v1.89.2

  region = var.region
  tenant = var.tenant
  env    = var.env
  azs    = var.azs

  ui_password         = var.ui_password
  allow_plaintext_alb = var.allow_plaintext_alb
  acm_certificate_arn = var.acm_certificate_arn

  proxy_config = var.proxy_config
  # Wire BEDROCK_API_KEY from the resolved secret (installer-minted TF-owned secret
  # by default, or the operator's own ARN when supplied) so a Codex-on install needs
  # no manual secret step. Merge so any other operator-supplied extra secrets survive. (#61)
  gateway_extra_secrets = var.enable_codex ? merge(var.gateway_extra_secrets, {
    BEDROCK_API_KEY = local.bedrock_api_key_secret_arn
  }) : var.gateway_extra_secrets

  # Pin the LiteLLM software to a current stable release (not the module's -dev default).
  gateway_image    = "ghcr.io/berriai/litellm-gateway:${var.image_tag}"
  backend_image    = "ghcr.io/berriai/litellm-backend:${var.image_tag}"
  ui_image         = "ghcr.io/berriai/litellm-ui:${var.image_tag}"
  migrations_image = "ghcr.io/berriai/litellm-migrations:${var.image_tag}"

  # minimal-size for a validation deploy
  gateway_desired_count = var.gateway_desired_count
  redis_num_replicas    = var.redis_num_replicas
  db_instance_class     = var.db_instance_class
  db_engine_version     = var.db_engine_version
  skip_final_snapshot   = var.skip_final_snapshot
  s3_force_destroy      = var.s3_force_destroy
}

output "alb_url" { value = module.litellm.alb_url }
output "alb_dns_name" { value = module.litellm.alb_dns_name }
output "master_key_secret_arn" { value = module.litellm.master_key_secret_arn }
output "migration_run_command" { value = module.litellm.migration_run_command }
output "aurora_writer_endpoint" { value = module.litellm.aurora_writer_endpoint }
output "redis_endpoint" { value = module.litellm.redis_endpoint }
output "ecs_cluster" { value = module.litellm.ecs_cluster }
output "alb_ingress_cidrs" { value = var.alb_ingress_cidrs }
