# One environment, built from modules/environment. Capstone B.
#
# This file is the same in every directory under infra/envs. What differs is
# terraform.tfvars (the inputs) and the backend key in versions.tf (the state).
# Set enabled = false and merge, and CI destroys the environment.
#
#   terraform init -backend-config=../../backend.hcl

module "env" {
  source = "../../modules/environment"
  count  = var.enabled ? 1 : 0

  environment          = var.environment
  api_image_digest     = var.api_image_digest
  data_noncurrent_days = var.data_noncurrent_days
}

# Before Capstone B the data bucket was a module of its own here. Harmless in
# an environment that never had it.
moved {
  from = module.data_bucket
  to   = module.env[0].module.data_bucket
}
