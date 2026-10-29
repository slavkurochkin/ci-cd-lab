# One ECR repository with a lifecycle policy.
#
# Extracted from infra/ecr in Project 8. The comments explaining *why* each
# setting is the default live in README.md, above the generated reference.

resource "aws_ecr_repository" "this" {
  #checkov:skip=CKV_AWS_136:AES256, not KMS. Images here are public on GHCR already; a KMS key would cost more than the registry.
  name                 = var.name
  image_tag_mutability = var.immutable_tags ? "IMMUTABLE" : "MUTABLE"

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  # No force_delete. Deleting a repository that still holds images should be
  # something you do on purpose, not a side effect of `terraform destroy`.

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  # ECR applies the first rule that matches, in priority order. Untagged images
  # go first so they never count against the tagged limit.
  #
  # Any change to this JSON replaces the policy, descriptions included. The
  # wording below matches what infra/ecr had before the module existed, so the
  # Project 8 refactor planned no changes.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = var.untagged_expiry_days == 1 ? "Expire untagged images after a day" : "Expire untagged images after ${var.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        # Capstone B. Environments run release images by digest, and a
        # release must outlive ten more merges to main. Matching the semver
        # tag puts releases under this rule, so the next one never counts
        # them.
        rulePriority = 2
        description  = "Keep the ${var.retained_releases} most recent releases"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*.*.*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.retained_releases
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "Keep the ${var.retained_images} most recent tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.retained_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
