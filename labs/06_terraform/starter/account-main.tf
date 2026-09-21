# Lab 06 -- real AWS resources, chosen because they are free (starter)
#
# An S3 bucket and a budget. Both cost nothing at this scale, and both teach
# something the sandbox module cannot.

# TODO(lab-06-d1): Create an S3 bucket.
#
# Bucket names are globally unique across every AWS account on earth, so build
# the name from the account ID -- there is a `data "aws_caller_identity"` in
# versions.tf for it. Without that, apply fails with BucketAlreadyExists for a
# bucket you cannot see and do not own.

# TODO(lab-06-d2): Secure it. This takes FOUR more resources, not four
# arguments:
#
#   aws_s3_bucket_versioning
#   aws_s3_bucket_server_side_encryption_configuration
#   aws_s3_bucket_public_access_block
#   aws_s3_bucket_lifecycle_configuration
#
# A bucket is not one object with settings. Each of these can simply be absent,
# and a bucket with none of them is a valid bucket that is versionless,
# unencrypted and potentially public. That is why "we have an S3 bucket" says
# nothing about whether it is safe.
#
# On the public access block: set all four flags. Each blocks a different
# route -- new ACLs, existing ACLs, new policies, existing policies. Setting
# two of the four is the usual near-miss, and it leaves whichever route was
# already open still open.
#
# On versioning: it has a second half. Versioning makes an overwrite
# recoverable and means deleted objects keep costing storage until something
# removes them. Give the lifecycle configuration a noncurrent_version_expiration
# or the bill grows with the number of edits rather than the amount of data.

# TODO(lab-06-e): Declare the budget that ALREADY EXISTS in your account.
#
# This one is different from every other resource in this curriculum: it is
# already there. It was created with the AWS CLI during setup, before any
# Terraform existed.
#
# Write the resource first, then run `terraform plan` and read what it says it
# will do. It will say "will be created". That apply would fail.
#
# The gap between "exists in the account" and "exists in state" is drift. A
# resource in that gap is invisible to plan, survives destroy, and collides
# with any apply that tries to create it. Close it with:
#
#   terraform import aws_budgets_budget.monthly "<account-id>:ci-cd-lab-monthly"
#
# Then plan again and read the difference. It will not be zero -- and what
# remains is the point of the exercise.
#
# Give it two notifications: FORECASTED at 80% and ACTUAL at 100%. A budget
# that only reports actual spend is a receipt. And note that neither one stops
# anything: a budget is a tripwire, not a cap.
