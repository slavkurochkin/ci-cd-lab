# A private, versioned, encrypted S3 bucket.
#
# These five resources started life in infra/account as top-level resources.
# They moved here in Project 7, and the `moved` blocks in infra/account are
# what kept that refactor from destroying and recreating the bucket.
# ../ecr-repository is the Project 8 module: same idea, with tests and
# generated docs.

resource "aws_s3_bucket" "this" {
  # checkov findings this module accepts, each on purpose. A skip with a
  # reason is a decision someone can revisit; a skip in a CI flag is not.
  #
  #checkov:skip=CKV_AWS_145:SSE-S3, not KMS. A KMS key is $1/month plus per-request charges, for an audit trail these buckets do not need.
  #checkov:skip=CKV_AWS_18:No access logging. It needs a second bucket per bucket and grows forever; these hold no data anyone reads.
  #checkov:skip=CKV_AWS_144:No cross-region replication. It doubles storage cost and these buckets have nothing worth a second region.
  #checkov:skip=CKV2_AWS_62:No event notifications. Nothing consumes events from these buckets.
  bucket = var.name
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}
