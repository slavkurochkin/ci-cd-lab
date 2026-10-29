terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Its own key, so its own state and its own lock. Nothing run in this
  # directory can read, lock or change another environment's state.
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "ci-cd-lab"
      Lab         = "07"
      Environment = var.environment
      ManagedBy   = "terraform"
      # Since Project 9, CI applies this environment. The tag says where to
      # look for the code and the run that last changed it.
      Repository = "slavkurochkin/ci-cd-lab"
    }
  }
}

