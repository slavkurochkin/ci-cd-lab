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

locals {
  # Every `sub` pattern the CI role's trust policy accepts. Flattened, because
  # a condition value can be one string or a list of them.
  ci_trusted_subjects = flatten([
    for statement in jsondecode(data.aws_iam_role.ci.assume_role_policy).Statement : [
      for operator, claims in try(statement.Condition, {}) : [
        for claim, value in claims : value
        if endswith(claim, ":sub")
      ]
    ]
  ])

  # A subject that anyone with a pull request or any branch can produce.
  ci_open_subjects = [
    for s in local.ci_trusted_subjects : s
    if endswith(s, ":*") || strcontains(s, ":pull_request") || strcontains(s, "refs/heads/*")
  ]
}

resource "aws_iam_role_policy" "ci_ecr_push" {
  name = "ecr-push"
  role = data.aws_iam_role.ci.name

  lifecycle {
    # The rule above, enforced. infra/ci-oidc owns the trust policy and this
    # stack cannot change it, but it can refuse to grant push access to a role
    # whose trust policy has been widened. A widened role still exists and
    # still works; it just gets nothing from this stack.
    precondition {
      condition     = length(local.ci_open_subjects) == 0
      error_message = "Refusing to grant ECR push: ${var.ci_role_name} trusts ${join(", ", local.ci_open_subjects)}. Pin its trust policy to a branch or environment in infra/ci-oidc first."
    }
  }

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
        Resource = [for r in module.repository : r.arn]
      },
    ]
  })
}

# Note what is absent: ecr:DeleteRepository, ecr:BatchDeleteImage,
# ecr:PutLifecyclePolicy. CI publishes; it does not curate. Retention is the
# lifecycle policy's job, and changing that is a Terraform change someone
# reviews.
