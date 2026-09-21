terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Local state, like the other stacks. Remote state is Project 8's subject.
  #
  # Losing this state file is recoverable but annoying: the repositories still
  # exist, so a fresh apply fails with RepositoryAlreadyExistsException and the
  # fix is `terraform import`. Unlike infra/eks there is no sweep script that
  # can find and delete these without Terraform, because unlike infra/eks they
  # are not supposed to be deleted.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "ci-cd-lab"
      Lab       = "capstone-a"
      ManagedBy = "terraform"
    }
  }
}
