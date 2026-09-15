terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Local state, like infra/eks. Remote state is Project 8's subject.
  #
  # The stakes are different here, though. infra/eks can lose its state safely
  # because `make eks-down` finds and deletes resources without Terraform's
  # help. This stack has no such fallback: lose the state and Terraform will
  # try to create an OIDC provider that already exists and fail with
  # EntityAlreadyExists. The recovery is `terraform import`, not a sweep.
  #
  # That asymmetry is the argument for remote state, and you now have a
  # concrete example of it rather than a general principle.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "ci-cd-lab"
      Lab       = "04"
      ManagedBy = "terraform"
    }
  }
}
