variable "region" {
  type    = string
  default = "us-east-1"
}

variable "tenant" {
  type        = string
  description = "Namespace prefix; resources become {tenant}-litellm-{env}"
}

variable "env" {
  type        = string
  description = "Environment suffix (e.g. prod)"
}

variable "azs" {
  type        = list(string)
  description = "At least 2 AZs for RDS/ALB"
}

variable "alb_ingress_cidrs" {
  type        = list(string)
  description = "IPv4 CIDRs allowed to reach the ALB. No default: every environment must explicitly define its allowlist."

  validation {
    condition     = length(var.alb_ingress_cidrs) > 0
    error_message = "alb_ingress_cidrs must contain at least one authorized IPv4 CIDR."
  }

  validation {
    condition     = alltrue([for cidr in var.alb_ingress_cidrs : can(cidrnetmask(cidr))])
    error_message = "alb_ingress_cidrs entries must be valid IPv4 CIDRs."
  }

  validation {
    condition     = alltrue([for cidr in var.alb_ingress_cidrs : length(regexall("/0+$", cidr)) == 0])
    error_message = "alb_ingress_cidrs must not contain a public /0 network."
  }

  validation {
    condition     = length(var.alb_ingress_cidrs) == length(distinct(var.alb_ingress_cidrs))
    error_message = "alb_ingress_cidrs must not contain duplicates."
  }
}

variable "ui_password" {
  type        = string
  sensitive   = true
  description = "Admin UI password (stored in Secrets Manager)"
}

variable "allow_plaintext_alb" {
  type        = bool
  default     = false
  description = "HTTP-only ALB (quick-start). Set false + acm_certificate_arn for HTTPS, or use CloudFront edge TLS, before production."
}

variable "acm_certificate_arn" {
  type    = string
  default = ""
}

variable "proxy_config" {
  type        = any
  description = "LiteLLM config.yaml contents (model_list, litellm_settings, general_settings)"
}

variable "gateway_extra_secrets" {
  type        = map(string)
  default     = {}
  description = "Extra gateway env vars sourced from Secrets Manager ARNs (e.g. BEDROCK_API_KEY)"
}

# Codex feature switch (#61). Default TRUE = Codex/gpt-5.x on out of the box.
# The installer AUTO-MINTS the initial BEDROCK_API_KEY: Terraform creates an empty
# secret (see codex-secret.tf), deploy.sh mints the short-term Bedrock token
# post-apply and writes it, and the refresher Lambda owns rotation from there. So a
# fresh Codex-on install needs NO manual secret step and NO pre-wired ARN. Operators
# who bring their own key can still pass gateway_extra_secrets.BEDROCK_API_KEY; when
# set, that ARN wins over the auto-created secret (see main.tf).
variable "enable_codex" {
  type        = bool
  default     = true
  description = "Enable Codex/gpt-5.x (OpenAI Responses route). Default true; the installer mints + rotates the Bedrock key automatically (no manual secret). Set false for a Claude-only install."

  # NOTE: the "Codex-on requires a valid key strategy" rule is enforced by a
  # resource precondition in codex-secret.tf, NOT a cross-variable validation{}
  # block here. Terraform only permits referencing OTHER variables inside a
  # variable validation from >= 1.9, and our supported floor is >= 1.5
  # (versions.tf) — a cross-var check here would be a latent portability bug on
  # 1.5–1.8. The precondition + preflight (deploy/preflight.sh) cover it. (#71/#76)
}

# Single front-door for the Codex key strategy (#76). Operators pick ONE mode
# instead of reasoning about enable_codex_key_refresh + gateway_extra_secrets.
# BEDROCK_API_KEY + codex_key_secret_arn. The mode DERIVES those internals
# (see codex-secret.tf locals); the raw flags remain accepted for back-compat,
# and when left at their defaults they follow the mode.
#
# The mode names the KEY-REFRESH PROCESS — who re-mints the Bedrock key. Key
# lifespan (short- vs long-lived) is orthogonal and NOT a mode: a durable key can
# sit behind either process too, so it isn't a separate choice.
#   lambda_auto_refresh (default)  — Terraform deploys a built-in scheduled Lambda
#       that re-mints the key. Fully automatic; today's default behavior.
#   external_cron_auto_refresh     — Terraform deploys NO refresher; you point the
#       gateway at a Secrets Manager key ARN (gateway_extra_secrets.BEDROCK_API_KEY)
#       and manage the key yourself: your own out-of-band cron re-mints a short-term
#       key, OR (if your key is durable) you simply never schedule one — same wiring.
#       For orgs whose SCP blocks lambda:CreateFunction. Install must not clobber
#       the BYO secret (#68/#69).
variable "codex_key_mode" {
  type        = string
  default     = "lambda_auto_refresh"
  description = "Codex key-refresh process: lambda_auto_refresh (default) | external_cron_auto_refresh. Front-door over enable_codex_key_refresh / BYO BEDROCK_API_KEY; see codex-secret.tf."

  validation {
    condition     = contains(["lambda_auto_refresh", "external_cron_auto_refresh"], var.codex_key_mode)
    error_message = "codex_key_mode must be one of: lambda_auto_refresh, external_cron_auto_refresh."
  }
}

# Pin the LiteLLM software version (module default is an older -dev tag).
variable "image_tag" {
  type    = string
  default = "v1.92.0" # latest stable at time of writing
}

# Minimal-size knobs (overridable per env via tfvars)
variable "gateway_desired_count" {
  type    = number
  default = 1
}
variable "redis_num_replicas" {
  type    = number
  default = 0
}
variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}
variable "db_engine_version" {
  type    = string
  default = "16.13" # module default (16.4) is not offered in us-east-1
}
variable "skip_final_snapshot" {
  type    = bool
  default = true
}
variable "s3_force_destroy" {
  type    = bool
  default = true
}
