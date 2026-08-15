terraform {
  required_version = ">= 1.5"
  required_providers {
    # ~> keeps upgrades within the tested major line (no silent jump to a new
    # major); the committed .terraform.lock.hcl pins the EXACT version + hash, so
    # a fresh init installs what we tested — upgrade only via `terraform init
    # -upgrade` (an explicit, reviewable change). (#26)
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

# Profile-driven: set AWS_PROFILE (and optionally AWS_REGION) in the environment.
# deploy.sh exports them; nothing here hardcodes an account.
provider "aws" {
  region = var.region
}
