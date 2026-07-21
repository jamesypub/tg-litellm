# CloudFront in front of the ALB — edge TLS + origin lock (issue #5).
#
# Why: the upstream LiteLLM module leaves the ALB open to 0.0.0.0/0 with no TLS
# cert (see #4). Fronting it with CloudFront terminates HTTPS at the edge (on the
# default *.cloudfront.net cert — no ACM cert or DNS needed) and lets us lock the
# ALB so only this distribution can reach it:
#   1. ALB SG ingress -> CloudFront's managed origin-facing prefix list
#      (done in restrict-ingress.sh, which owns the SG the module hides from TF).
#   2. A secret header this distribution injects, which the ALB 403s when absent
#      (also enforced in restrict-ingress.sh via an ALB listener rule).
# The prefix list alone is not a lock (any CloudFront distro egresses those IPs);
# the secret header is the actual "only our CloudFront" guarantee.
#
# Streaming: LLM SSE/token streaming is safe through CloudFront — it relays
# Transfer-Encoding: chunked bodies progressively. The behavior below uses the
# managed CachingDisabled policy (also disables request collapsing) + AllViewer
# origin request policy, allows POST, and raises the origin read timeout so a
# long first-token gap does not trip CloudFront's idle timeout.

variable "enable_cloudfront" {
  type        = bool
  default     = false
  description = "Front the ALB with CloudFront (edge TLS + origin lock). See issue #5."
}

variable "cloudfront_origin_read_timeout" {
  type    = number
  default = 60 # #46: this is an INTER-PACKET (idle) timeout — a no-output gap longer
  # than this closes the stream mid-response ("Connection closed mid-response").
  # 60 is CloudFront's universal default and applies under ANY account quota. Values
  # above 60 require a per-account CloudFront "Response timeout per origin" Service
  # Quotas increase; without it, apply fails `InvalidOriginReadTimeout` (learned the
  # hard way on demo2). So the DEFAULT stays 60 (portable); raise it toward 180 (the
  # common ceiling) ONLY after the quota is granted. LiteLLM has no client SSE
  # keep-alive to keep a stream warm (researched on #46), so headroom is the fix once
  # the quota allows it. See the streaming FAQ in docs/installer.md.
  description = "CloudFront origin response (idle/inter-packet) timeout in seconds. Default 60 (portable — applies under any account quota). Raise toward 180 for long LLM thinking pauses AFTER a CloudFront 'Response timeout per origin' Service Quotas increase."

  validation {
    condition     = var.cloudfront_origin_read_timeout >= 30 && var.cloudfront_origin_read_timeout <= 180
    error_message = "cloudfront_origin_read_timeout must be 30–180 (values above your account's CloudFront origin-timeout quota — 60 by default — fail apply until you request a Service Quotas increase)."
  }
}

# Custom viewer certificate for CloudFront (#49). Enforcing a TLS 1.2+ viewer
# minimum requires a CUSTOM ACM cert (us-east-1) + domain aliases; the default
# *.cloudfront.net cert cannot enforce it. Leave empty for the default-cert path
# (edge minimum stays CloudFront's default; documented in the installer FAQ).
variable "cloudfront_acm_certificate_arn" {
  type        = string
  default     = ""
  description = "us-east-1 ACM certificate ARN for a custom CloudFront domain. Set with cloudfront_aliases to enforce a TLS 1.2+ viewer minimum. Empty = default *.cloudfront.net cert (no enforceable minimum)."

  validation {
    condition     = var.cloudfront_acm_certificate_arn == "" || can(regex("^arn:aws:acm:us-east-1:", var.cloudfront_acm_certificate_arn))
    error_message = "cloudfront_acm_certificate_arn must be a us-east-1 ACM ARN (CloudFront requires us-east-1) or empty."
  }
}

variable "cloudfront_aliases" {
  type        = list(string)
  default     = []
  description = "Custom domain name(s) (CNAMEs) for the CloudFront distribution. Required when cloudfront_acm_certificate_arn is set."

  validation {
    condition     = (var.cloudfront_acm_certificate_arn == "") == (length(var.cloudfront_aliases) == 0)
    error_message = "Set cloudfront_aliases and cloudfront_acm_certificate_arn together (a custom cert needs at least one alias)."
  }
}

variable "cloudfront_price_class" {
  type        = string
  default     = "PriceClass_100"
  description = "CloudFront price class (PriceClass_100 = NA+EU, cheapest; _200 adds more; _All = everywhere)."

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "cloudfront_price_class must be PriceClass_100, PriceClass_200, or PriceClass_All."
  }
}

# AWS-managed CloudFront policies (well-known, resolved by name so nothing is
# hardcoded to an ID that could drift).
data "aws_cloudfront_cache_policy" "caching_disabled" {
  count = var.enable_cloudfront ? 1 : 0
  name  = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  count = var.enable_cloudfront ? 1 : 0
  name  = "Managed-AllViewer"
}

# The shared secret CloudFront injects and the ALB requires. Generated once and
# kept in state; restrict-ingress.sh reads it via the cloudfront_origin_secret
# output to build the ALB listener rule.
resource "random_password" "cloudfront_origin_secret" {
  count   = var.enable_cloudfront ? 1 : 0
  length  = 48
  special = false
}

# Security response headers at the edge (#15 clickjacking, #16 missing CSP).
# The admin UI is upstream LiteLLM; we harden what we control — the edge — with
# anti-framing + a strict frame-ancestors CSP and HSTS. (Note: the UI's own
# token cookie httpOnly/Secure flags are set by upstream LiteLLM, not here — see
# #16; HTTPS is enforced end-to-end via viewer_protocol_policy=redirect-to-https.)
resource "aws_cloudfront_response_headers_policy" "security" {
  count = var.enable_cloudfront ? 1 : 0
  name  = "${var.tenant}-litellm-${var.env}-security-headers"

  security_headers_config {
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    content_type_options {
      override = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
    }
    content_security_policy {
      content_security_policy = "frame-ancestors 'none'"
      override                = true
    }
  }
}

resource "aws_cloudfront_distribution" "this" {
  count = var.enable_cloudfront ? 1 : 0

  enabled         = true
  comment         = "${var.tenant}-litellm-${var.env} gateway (issue #5: edge TLS + ALB origin lock)"
  price_class     = var.cloudfront_price_class
  is_ipv6_enabled = true
  http_version    = "http2and3"
  aliases         = var.cloudfront_aliases # custom domain(s); required with a custom ACM cert (#49)

  origin {
    origin_id   = "alb"
    domain_name = module.litellm.alb_dns_name

    # Talk to the ALB over plain HTTP: the origin has no cert, and the origin
    # lock (prefix list + secret header) protects this leg. TLS is terminated at
    # the edge for the public (viewer) leg.
    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = var.cloudfront_origin_read_timeout
      origin_keepalive_timeout = 60
    }

    # Secret shared with the ALB listener rule (enforced in restrict-ingress.sh).
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.cloudfront_origin_secret[0].result
    }
  }

  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    compress               = false # never compress a token stream

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    # CachingDisabled also disables request collapsing (which would pause
    # concurrent per-request LLM calls). AllViewer forwards Authorization,
    # Content-Type, the body, etc.
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer[0].id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Viewer TLS (#49). IMPORTANT: with the default *.cloudfront.net certificate,
  # CloudFront IGNORES minimum_protocol_version and pins the viewer minimum to
  # TLSv1 — so declaring TLSv1.2_2021 there is ineffective AND causes perpetual
  # plan drift (AWS normalizes it back every apply). A minimum of TLS 1.2+ is only
  # honored with a CUSTOM ACM certificate (+ domain aliases). So:
  #   - custom ACM cert set  -> enforce TLSv1.2_2021 (effective).
  #   - default cert -> DO NOT declare a minimum we can't enforce; the
  #     edge uses CloudFront's default (TLSv1) minimum. Documented in the FAQ.
  # To actually enforce TLS 1.2+ at the viewer, provide cloudfront_acm_certificate_arn
  # (a us-east-1 ACM cert) + aliases.
  dynamic "viewer_certificate" {
    for_each = var.cloudfront_acm_certificate_arn == "" ? [1] : []
    content {
      cloudfront_default_certificate = true
      # Deliberately no viewer TLS floor here — the default cert can't enforce one,
      # and declaring it would drift every apply. See the FAQ + custom-cert branch.
    }
  }
  dynamic "viewer_certificate" {
    for_each = var.cloudfront_acm_certificate_arn == "" ? [] : [1]
    content {
      acm_certificate_arn      = var.cloudfront_acm_certificate_arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021" # effective only with a custom cert
    }
  }

  tags = {
    "litellm:stack" = "${var.tenant}-litellm-${var.env}"
  }
}

# --- Origin lock, layer 2: WAF on the ALB requires the secret header ---------
# The SG prefix-list rule (restrict-ingress.sh) already blocks non-CloudFront IPs.
# This WAF is defense-in-depth: any CloudFront distribution egresses those IPs,
# so we also require the secret header this distribution injects. A REGIONAL WAF
# on the ALB (not a CLOUDFRONT-scope one on the distribution) is what enforces
# the ORIGIN leg. It does not touch the module's listener/path-routing rules.

# Resolve the module's ALB by its DNS name (a module output that is KNOWN at plan
resource "aws_wafv2_web_acl" "origin_lock" {
  count       = var.enable_cloudfront ? 1 : 0
  name        = "${var.tenant}-litellm-${var.env}-origin-lock"
  description = "Block ALB requests without the CloudFront secret header - issue 5"
  scope       = "REGIONAL"

  default_action {
    block {}
  }

  rule {
    name     = "allow-cloudfront-secret-header"
    priority = 0

    action {
      allow {}
    }

    statement {
      byte_match_statement {
        field_to_match {
          single_header {
            name = "x-origin-verify" # WAF lowercases header names
          }
        }
        positional_constraint = "EXACTLY"
        search_string         = random_password.cloudfront_origin_secret[0].result
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "origin-lock-allow"
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.tenant}-litellm-${var.env}-origin-lock"
    sampled_requests_enabled   = false
  }

  tags = {
    "litellm:stack" = "${var.tenant}-litellm-${var.env}"
  }
}

# NOTE: the WAF→ALB *association* is intentionally NOT a Terraform resource.
# A data "aws_lb" lookup for the association's resource_arn cannot satisfy both
# constraints at once: plan-time lookup fails on first install (ALB not yet
# created, #10-class), while depends_on defers the arn to unknown and forces the
# association to be REPLACED every apply (public + WAF-less window, #12). The
# module also does not output the ALB ARN. So restrict-ingress.sh (which resolves
# the ALB from AWS after apply, when it always exists) OWNS the association: it
# associates/re-asserts the origin_lock WebACL to the ALB in CloudFront mode. The
# WebACL itself stays declarative here; only the binding is imperative. (#12)

output "origin_lock_web_acl_arn" {
  value       = var.enable_cloudfront ? aws_wafv2_web_acl.origin_lock[0].arn : ""
  description = "ARN of the origin-lock WAF; restrict-ingress.sh associates it to the ALB post-apply."
}

output "cloudfront_url" {
  value       = var.enable_cloudfront ? "https://${aws_cloudfront_distribution.this[0].domain_name}" : ""
  description = "Public HTTPS entrypoint (empty when CloudFront is disabled). Hand this to clients instead of alb_url."
}

output "cloudfront_origin_secret" {
  value       = var.enable_cloudfront ? random_password.cloudfront_origin_secret[0].result : ""
  sensitive   = true
  description = "Secret CloudFront injects as X-Origin-Verify; restrict-ingress.sh enforces it on the ALB."
}

output "cloudfront_enabled" {
  value = var.enable_cloudfront
}

# Exposes the configured CloudFront origin read (idle) timeout so deploy.sh can
# reconcile the ALB idle timeout to match it — instead of guessing a stale
# constant when the output is absent (#46).
output "cloudfront_origin_read_timeout" {
  value = var.cloudfront_origin_read_timeout
}
