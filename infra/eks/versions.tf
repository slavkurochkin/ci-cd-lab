terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Local state, deliberately. Remote state with locking is Project 8's subject,
  # and bootstrapping an S3 backend here would mean teaching it twice. The
  # cluster is recreated from scratch every session anyway, so the blast radius
  # of a lost state file is one `make eks-down` run against a live account --
  # which is exactly what scripts/eks-down.sh handles without Terraform's help.
}

provider "aws" {
  region = var.region

  # Every resource carries these. Project 18's Slack cost report groups by them,
  # and cost allocation tags do not apply retroactively -- an untagged resource
  # is permanently unattributable, so the tagging happens at creation or not at all.
  default_tags {
    tags = {
      Project   = "ci-cd-lab"
      Lab       = "13"
      ManagedBy = "terraform"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
