terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # State lives in S3 since Project 7. Lose it and the next apply fails
  # with RepositoryAlreadyExistsException, because the repositories are still
  # there with the images in them.
  # The bucket name is in ../backend.hcl:
  #
  #   terraform init -backend-config=../backend.hcl
  backend "s3" {
    key          = "ecr/terraform.tfstate"
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
      Lab       = "capstone-a"
      ManagedBy = "terraform"
    }
  }
}
