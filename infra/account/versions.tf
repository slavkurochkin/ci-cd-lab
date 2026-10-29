terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # State lives in S3 since Project 7. Nothing here can be swept
  # or rebuilt without it, and the budget would have to be imported again.
  # The bucket name is in ../backend.hcl:
  #
  #   terraform init -backend-config=../backend.hcl
  backend "s3" {
    key          = "account/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "ci-cd-lab"
      Lab       = "06"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
