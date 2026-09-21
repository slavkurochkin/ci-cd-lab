# Account-level resources that are effectively free and meant to persist.
#
# Two things live here, and the second one is a lesson rather than a resource.

# ---------------------------------------------------------------------------
# An S3 bucket, secured the way every S3 bucket should be
# ---------------------------------------------------------------------------
#
# Note how many separate resources this takes. A bucket is not one object with
# settings; it is a bucket plus four independent configurations, each of which
# can be absent. That is why "we have an S3 bucket" says nothing about whether
# it is safe, and why the checkov rules in Project 9 exist.

resource "aws_s3_bucket" "artifacts" {
  # Bucket names are globally unique across every AWS account on earth, so the
  # account ID is part of the name. Without it, `terraform apply` fails with
  # BucketAlreadyExists for a bucket you cannot see and do not own.
  bucket = "ci-cd-lab-artifacts-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    # Versioning makes an overwrite recoverable and a delete reversible. It
    # also means deleted objects still cost storage until a lifecycle rule
    # removes them -- safety and cost point in opposite directions here.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3. AWS manages the key, and it costs nothing. SSE-KMS gives you an
      # audit trail of key use and charges per request, which is worth it for
      # data you would have to report on and not for build artifacts.
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  # All four, deliberately. Each blocks a different route to public:
  #   - block_public_acls:       new ACLs that grant public access
  #   - ignore_public_acls:      ACLs that already exist
  #   - block_public_policy:     new bucket policies that grant public access
  #   - restrict_public_buckets: policies that already exist
  #
  # Setting two of the four is the usual near-miss, and it leaves the route
  # that was already open still open.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      # The other half of versioning. Without this, every overwrite is kept
      # forever and the bill grows with the number of edits rather than the
      # amount of data.
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.artifacts]
}

# ---------------------------------------------------------------------------
# The budget
# ---------------------------------------------------------------------------
#
# This budget already existed before this module did -- it was created with
# the AWS CLI while setting up the account. Terraform did not know about it.
#
# That gap has a name: drift. A resource that exists in the account and not in
# state is invisible to `plan`, survives `destroy`, and will collide with any
# apply that tries to create it. `terraform import` is how it is closed, and
# doing that here is the point of including a resource you already have.
#
#   terraform import aws_budgets_budget.monthly <account-id>:ci-cd-lab-monthly

resource "aws_budgets_budget" "monthly" {
  name         = "ci-cd-lab-monthly"
  budget_type  = "COST"
  limit_amount = var.budget_limit
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Forecast, not actual. A budget that tells you when you have already spent
  # the money is a receipt. This fires when AWS projects you will exceed it.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  # And once on actual spend, because a forecast can be wrong in both
  # directions.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
