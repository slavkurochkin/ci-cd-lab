# The prod environment: the same module as ../dev, with its own state and its
# own settings.
#
#   terraform init -backend-config=../../backend.hcl

module "data_bucket" {
  source = "../../modules/s3-bucket"

  name = "ci-cd-lab-prod-${data.aws_caller_identity.current.account_id}"

  # A bad overwrite in prod tends to be found late, so keep a quarter of history.
  noncurrent_days = 90
}
