# The dev environment: the same module as ../prod, with its own state and its
# own settings.
#
#   terraform init -backend-config=../../backend.hcl

module "data_bucket" {
  source = "../../modules/s3-bucket"

  name = "ci-cd-lab-dev-${data.aws_caller_identity.current.account_id}"

  # Losing old dev versions costs little. A week covers "I overwrote that
  # yesterday".
  noncurrent_days = 7
}
