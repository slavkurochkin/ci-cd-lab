# Push access for the CI role.
#
# This is the first time ci-cd-lab-ci is granted anything at all. Until now it
# could prove its own identity and do nothing else, which is why its trust
# policy could safely accept any branch or pull request.
#
# That is no longer true, and infra/ci-oidc narrows the subject accordingly:
#
#   A role that grants nothing may use `:*`. A role that can change anything is
#   pinned to a branch or an environment.
#
# Without that narrowing, anyone who could open a pull request against this
# repository could push an image to it.

data "aws_iam_role" "ci" {
  name = var.ci_role_name
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "ci_ecr_push" {
  name = "ecr-push"
  role = data.aws_iam_role.ci.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The token call is account-wide by definition -- there is no resource
        # to scope it to. It grants nothing on its own.
        Sid      = "GetAuthorizationToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # Everything else is scoped to these two repositories by ARN. A role
        # that can push anywhere in the account is a role that can overwrite
        # something you did not mean to.
        Sid    = "PushToLabRepositories"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          # Reads, so the build can reuse layers it already pushed.
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [for r in aws_ecr_repository.service : r.arn]
      },
    ]
  })
}

# Note what is absent: ecr:DeleteRepository, ecr:BatchDeleteImage,
# ecr:PutLifecyclePolicy. CI publishes; it does not curate. Retention is the
# lifecycle policy's job, and changing that is a Terraform change someone
# reviews.
