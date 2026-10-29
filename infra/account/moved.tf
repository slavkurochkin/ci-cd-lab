# Project 7: the five bucket resources moved from this file into a module.
#
# Without these blocks the plan reads "5 to add, 0 to change, 5 to destroy":
# Terraform sees five addresses it no longer has and five it has never seen,
# and does not know they are the same bucket. Each block tells it so.
#
# They can be deleted once every copy of this state has been applied past
# them. There is one copy, in S3, and it has been. They stay as a record.

moved {
  from = aws_s3_bucket.artifacts
  to   = module.artifacts.aws_s3_bucket.this
}

moved {
  from = aws_s3_bucket_versioning.artifacts
  to   = module.artifacts.aws_s3_bucket_versioning.this
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.artifacts
  to   = module.artifacts.aws_s3_bucket_server_side_encryption_configuration.this
}

moved {
  from = aws_s3_bucket_public_access_block.artifacts
  to   = module.artifacts.aws_s3_bucket_public_access_block.this
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.artifacts
  to   = module.artifacts.aws_s3_bucket_lifecycle_configuration.this
}
