terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Local state, still, after Project 7 moved the long-lived stacks to S3. The
  # cluster is recreated from scratch every session, so the blast radius of a
  # lost state file is one `make eks-down` run against a live account, and
  # scripts/eks-down.sh handles that without Terraform's help. CI deploys to
  # the cluster but never applies this stack, so nothing else needs the state.
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
