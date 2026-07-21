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

  validation {
    # When Codex is enabled, the key refresher must be on (the key has a ~12h TTL).
    condition     = !var.enable_codex || var.enable_codex_key_refresh
    error_message = "enable_codex = true requires enable_codex_key_refresh = true (the Bedrock API key expires ~12h)."
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
