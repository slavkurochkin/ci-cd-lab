terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Persistent, like infra/account and infra/ci-oidc:
  #
  #   terraform init -backend-config=../backend.hcl
  backend "s3" {
    key          = "cost-report/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "ci-cd-lab"
      Lab       = "18"
      ManagedBy = "terraform"
    }
  }
}
