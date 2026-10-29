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

# DEMO -- Project 9. Must never merge: this PR exists to be blocked by policy.
resource "aws_s3_bucket" "shared" {
  bucket = "ci-cd-lab-dev-shared-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "shared" {
  bucket = aws_s3_bucket.shared.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}
