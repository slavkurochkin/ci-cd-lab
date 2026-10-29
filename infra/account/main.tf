# Account-level resources that are effectively free and meant to persist.
#
# Two things live here, and the second one is a lesson rather than a resource.

# ---------------------------------------------------------------------------
# An S3 bucket, secured the way every S3 bucket should be
# ---------------------------------------------------------------------------
#
# A bucket is five resources: the bucket plus four independent configurations,
# each of which can be absent. Until Project 7 all five were written out here.
# They now live in ../modules/s3-bucket, shared with the state bucket and the
# dev and prod roots. README.md explains each setting.

module "artifacts" {
  source = "../modules/s3-bucket"

  # Bucket names are globally unique across every AWS account, so the account
  # ID is part of the name.
  name = "ci-cd-lab-artifacts-${data.aws_caller_identity.current.account_id}"
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
