# One environment: a data bucket and the api service. Capstone B.
#
# Every environment is this module with different inputs. The roots in
# infra/envs/<env>/ are identical files apart from terraform.tfvars and the
# backend key, so "a second environment" is a copied directory and one tfvars
# file.

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

module "data_bucket" {
  source = "../s3-bucket"

  name            = "ci-cd-lab-${var.environment}-${local.account_id}"
  noncurrent_days = var.data_noncurrent_days
}

module "api" {
  source = "../api-service"

  name_prefix  = "ci-cd-lab-${var.environment}"
  environment  = var.environment
  image_digest = var.api_image_digest

  # Built from the account ID rather than looked up, so planning needs no
  # iam:GetPolicy. infra/ci-oidc creates it.
  permissions_boundary_arn = "arn:aws:iam::${local.account_id}:policy/ci-cd-lab-lambda-boundary"
}
