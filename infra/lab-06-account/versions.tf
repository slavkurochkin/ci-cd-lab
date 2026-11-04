terraform {
  # Local state, on purpose. This directory is Lab 06's practice copy of
  # infra/account. It must never share state with the real one, which lives in
  # S3 from Project 7 on.
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
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
