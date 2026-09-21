terraform {
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
