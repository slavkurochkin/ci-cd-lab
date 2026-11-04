# The bucket that holds every other root module's state, including this one's.
#
# It was created with the AWS CLI first, because Terraform needs somewhere to
# keep state before it can create anything. The import blocks below adopt what
# the CLI made. They stay in the file: once imported, an import block is a
# no-op, and it records where these resources came from.

locals {
  bucket = "ci-cd-lab-tfstate-${data.aws_caller_identity.current.account_id}"
}

module "state_bucket" {
  source = "../modules/s3-bucket"

  name = local.bucket

  # State is small and every apply writes a new version. 90 days of history is
  # how far back you can roll a state file after a bad apply or a bad `state rm`.
  noncurrent_days = 90
}

# The CLI-created bucket, and the two settings AWS turns on for every new
# bucket since 2023. Versioning and lifecycle do not exist yet, so the plan
# creates them.
import {
  to = module.state_bucket.aws_s3_bucket.this
  id = local.bucket
}

import {
  to = module.state_bucket.aws_s3_bucket_server_side_encryption_configuration.this
  id = local.bucket
}

import {
  to = module.state_bucket.aws_s3_bucket_public_access_block.this
  id = local.bucket
}
