terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Added only after the first apply. See README.md: this root stored its state
  # on disk until the bucket it describes existed, then moved into it.
  backend "s3" {
    key          = "state/terraform.tfstate"
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
      Lab       = "07"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
