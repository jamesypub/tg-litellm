# Codex/Mantle BEDROCK_API_KEY secret — Terraform-owned (#61).
#
# Codex is on by default. The Mantle/Responses leg authenticates with a short-term
# Bedrock API key (bearer, ~12h TTL). Rather than make the operator create that
# secret out-of-band, Terraform creates it EMPTY here and the installer mints the
# first token into it post-apply (deploy.sh), after which the refresher Lambda owns
# rotation. Terraform owning the secret means one `destroy` tears it down with the
# rest of the stack (no orphaned secret) — important for clean fresh-account rebuilds.
#
# Bring-your-own-key: if the operator sets gateway_extra_secrets.BEDROCK_API_KEY to
# their own ARN, that wins (see local.bedrock_api_key_secret_arn) and this resource
# is still created but simply goes unused by the gateway wiring.

resource "aws_secretsmanager_secret" "bedrock_api_key" {
  count = var.enable_codex ? 1 : 0
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
}

# Surface the resolved ARN so deploy.sh can mint the initial token into it.
output "bedrock_api_key_secret_arn" {
  value       = local.bedrock_api_key_secret_arn
  description = "Secrets Manager ARN of the Codex/Mantle BEDROCK_API_KEY the installer mints into (empty when Codex is disabled)."
}
