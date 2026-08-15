# Codex/Mantle BEDROCK_API_KEY secret — Terraform-owned (#61).
#
# Codex is on by default. The Mantle/Responses leg authenticates with a short-term
# Bedrock API key (bearer, ~12h TTL). Rather than make the operator create that
# secret out-of-band, Terraform creates it EMPTY here and the installer mints the
# first token into it post-apply (deploy.sh), after which the refresher Lambda owns
# rotation. Terraform owning the secret means one `destroy` tears it down with the
# rest of the stack (no orphaned secret) — important for clean fresh-account rebuilds.
#
# Bring-your-own-key: if the operator supplies their own key ARN
# (gateway_extra_secrets.BEDROCK_API_KEY or codex_key_secret_arn), that wins and
# this Terraform-owned secret is NOT created at all. Creating it anyway was both
# pointless (the gateway reads the BYO ARN via local.bedrock_api_key_secret_arn)
# AND a hard failure when a same-named secret already exists in the account
# (ResourceExistsException) — e.g. upgrading a retained env whose pre-existing
# Codex secret shares this deterministic name. Gating on local.codex_byo_key_present
# is plan-time safe: it derives only from input variables (see locals below), never
# an apply-time attribute, so it's valid in `count`. (#79)
resource "aws_secretsmanager_secret" "bedrock_api_key" {
  count = var.enable_codex && !local.codex_byo_key_present ? 1 : 0
  # Include the stack namespace so it's discoverable and collision-free per env.
  name        = "${var.tenant}-litellm-${var.env}-bedrock-api-key"
  description = "Short-term Bedrock API key (bearer) for the Codex/Mantle Responses route. Minted by the installer, rotated by the codex-key-refresher Lambda. (#61)"

  # Fresh rebuilds (e.g. QA #62) must not collide with a same-named secret still in
  # AWS's 7–30 day recovery window from a prior destroy.
  recovery_window_in_days = 0
}

locals {
  # The secret ARN the gateway reads and the refresher rotates. Precedence:
  #   1. operator-supplied gateway_extra_secrets.BEDROCK_API_KEY (bring-your-own)
  #   2. explicit codex_key_secret_arn override
  #   3. the Terraform-owned secret created above (default path)
  byo_bedrock_api_key    = lookup(var.gateway_extra_secrets, "BEDROCK_API_KEY", "")
  bedrock_api_key_secret_arn = (
    local.byo_bedrock_api_key != "" ? local.byo_bedrock_api_key :
    var.codex_key_secret_arn != "" ? var.codex_key_secret_arn :
    var.enable_codex ? aws_secretsmanager_secret.bedrock_api_key[0].arn : ""
  )

  # --- codex_key_mode derivation (#76) ---------------------------------------
  # The mode names the key-REFRESH PROCESS; it derives whether Terraform deploys a
  # refresher. The raw enable_codex_key_refresh flag is honored for back-compat,
  # but external_cron_auto_refresh forces the TF refresher OFF:
  #   lambda_auto_refresh        -> TF deploys the built-in Lambda (this file's engine)
  #   external_cron_auto_refresh -> TF deploys NO refresher; operator manages the BYO key
  #       (own cron re-mints a short-term key, or a durable key needs nothing).
  codex_tf_managed_refresh = var.codex_key_mode == "lambda_auto_refresh"
  codex_refresh_on         = local.codex_tf_managed_refresh ? var.enable_codex_key_refresh : false

  # external_cron_auto_refresh wires the gateway to a caller-supplied (non-installer)
  # key ARN — no TF refresher exists to create one.
  codex_byo_key_present = local.byo_bedrock_api_key != "" || var.codex_key_secret_arn != ""
}

# Plan-time guard for the Codex key strategy (#76). Uses terraform_data (built-in,
# TF >= 1.4) so the preconditions evaluate on every plan without depending on a
# counted resource. Replaces the old cross-variable validation{} block in
# variables.tf that only worked on TF >= 1.9 (our floor is >= 1.5).
resource "terraform_data" "codex_key_mode_guard" {
  input = var.codex_key_mode

  lifecycle {
    # lambda_auto_refresh mints a SHORT-TERM (~12h) key, so the TF-managed
    # refresher must be on; a disabled refresher would let the key expire.
    # (Replaces the removed enable_codex => enable_codex_key_refresh cross-var
    # validation that only worked on TF >= 1.9.)
    precondition {
      condition     = !(var.enable_codex && var.codex_key_mode == "lambda_auto_refresh") || local.codex_refresh_on
      error_message = "codex_key_mode = \"lambda_auto_refresh\" needs the refresher on (the minted Bedrock key expires ~12h). Leave enable_codex_key_refresh at its default (true), or choose external_cron_auto_refresh to manage the key with your own cron."
    }

    # external_cron_auto_refresh deploys no TF refresher, so the gateway must be
    # wired to a caller-supplied secret ARN (your cron re-mints a short-term key
    # into it, or it holds a durable key — either way you supply it).
    precondition {
      condition     = !(var.enable_codex && var.codex_key_mode == "external_cron_auto_refresh") || local.codex_byo_key_present
      error_message = "codex_key_mode = \"external_cron_auto_refresh\" requires a Secrets Manager key ARN: set gateway_extra_secrets.BEDROCK_API_KEY (or codex_key_secret_arn). Your own cron re-mints a short-term key into it (see docs/codex-cron-key-refresh.md), or it holds a durable key. See #69."
    }
  }
}

# Surface the resolved ARN so deploy.sh can mint the initial token into it.
output "bedrock_api_key_secret_arn" {
  value       = local.bedrock_api_key_secret_arn
  description = "Secrets Manager ARN of the Codex/Mantle BEDROCK_API_KEY the installer mints into (empty when Codex is disabled)."
}
