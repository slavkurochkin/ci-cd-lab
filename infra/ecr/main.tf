# Container registry for the images the pipeline builds.
#
# This exists rather than GHCR alone because Track C pulls from it. EKS pulling
# from GHCR needs an image pull secret -- a stored credential, which is exactly
# what Project 4 spent its time removing. ECR plus IAM needs no secret.
#
# Cost: about $0.015/month per retained version pair, and the first 500 MB of
# private storage is free for twelve months. The lifecycle policy below is what
# keeps it there.

resource "aws_ecr_repository" "service" {
  for_each = toset(var.services)

  name = "ci-cd-lab/${each.value}"

  # A tag that cannot be repointed.
  #
  # Everything in this curriculum argues that a digest is the only identifier
  # that cannot lie to you. This makes the registry enforce it: pushing
  # `0.1.0` twice fails rather than silently changing what `0.1.0` means.
  #
  # The cost is that a failed release cannot be re-cut under the same version.
  # That is the correct trade -- a version that meant two different things is
  # worse than a version number you skipped.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # ECR's own scan, in addition to the Trivy gate in CI.
    #
    # Not redundant: Trivy scans at build time and answers "should this ship".
    # This scans continuously against a feed that keeps moving, and answers
    # "is something we shipped last month now known to be vulnerable". A gate
    # cannot ask the second question.
    scan_on_push = true
  }

  # Deliberately not `force_delete`. Emptying a registry should be something
  # you do on purpose, not something a `terraform destroy` does quietly.
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = aws_ecr_repository.service
  repository = each.value.name

  # The only thing between a per-merge push and an unbounded bill.
  #
  # Rules are evaluated in order and an image is expired by the first one that
  # matches, so the untagged rule comes first: an untagged image is a layer
  # orphaned by a retag, and nothing will ever pull it.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after a day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
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
