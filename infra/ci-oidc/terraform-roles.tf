# Project 9: roles for Terraform in CI.
#
# Three roles, so each job can do exactly one kind of thing:
#
#   ci-cd-lab-tf-plan         read-only. Any pull request may assume it.
#   ci-cd-lab-tf-apply-dev    writes dev.  Only a job in the infra-dev environment.
#   ci-cd-lab-tf-apply-prod   writes prod. Only a job in the infra-prod
#                             environment, which needs a human to approve.
#
# CI manages infra/envs/* and nothing else. The stacks that write IAM
# (ci-oidc, ecr) stay applied from a laptop: a role that can write IAM can
# grant itself anything, and Capstone B is where that gets solved properly.

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  state_bucket = "ci-cd-lab-tfstate-${local.account_id}"
  environments = toset(["dev", "prod"])

  # Both spellings of the repository, for the reason given on the CI role's
  # trust policy in main.tf.
  repo_subjects = [
    "repo:${var.github_repo}",
    "repo:${local.owner}@${var.github_owner_id}/${local.name}@${var.github_repo_id}",
  ]
}

# ---------------------------------------------------------------------------
# Plan: read-only, and the only role a pull request can reach
# ---------------------------------------------------------------------------

resource "aws_iam_role" "tf_plan" {
  name        = "ci-cd-lab-tf-plan"
  description = "Terraform plan for infra/envs from GitHub Actions. Reads; never writes."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Pull requests, and main for the nightly drift check.
        #
        # This is the subject the CI role refuses (see main.tf). It is safe
        # here only because of what the policy below does not contain: no
        # write to any resource, and no read of any state file outside envs/.
        # The precondition in infra/ecr would refuse to give this role push
        # access, and that is correct.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = flatten([
            for s in local.repo_subjects : ["${s}:pull_request", "${s}:ref:refs/heads/main"]
          ])
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "tf_plan" {
  name = "plan-envs"
  role = aws_iam_role.tf_plan.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # State for infra/envs only. State files hold every attribute in plain
        # text, so reading ci-oidc's or account's state would be reading more
        # than a dev plan needs.
        Sid      = "ReadEnvState"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["arn:aws:s3:::${local.state_bucket}/envs/*/terraform.tfstate"]
      },
      {
        Sid      = "ListEnvState"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::${local.state_bucket}"]
        Condition = {
          StringLike = { "s3:prefix" = ["envs/*"] }
        }
      },
      {
        # plan takes the lock too, so two plans and an apply cannot interleave.
        # The lock is a separate object; writing it cannot change state.
        Sid      = "LockEnvState"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = ["arn:aws:s3:::${local.state_bucket}/envs/*/terraform.tfstate.tflock"]
      },
      {
        # Refreshing a bucket reads about fifteen separate configurations.
        # Get*/List* on the bucket ARN only: these are bucket-level reads,
        # and they do not reach the objects inside.
        Sid    = "RefreshEnvBuckets"
        Effect = "Allow"
        Action = ["s3:Get*", "s3:List*"]
        Resource = [
          for env in local.environments : "arn:aws:s3:::ci-cd-lab-${env}-${local.account_id}"
        ]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Apply: one role per environment, reachable only from that environment
# ---------------------------------------------------------------------------

resource "aws_iam_role" "tf_apply" {
  for_each = local.environments

  name        = "ci-cd-lab-tf-apply-${each.key}"
  description = "Terraform apply for infra/envs/${each.key}. Only from the infra-${each.key} GitHub environment."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # A job gets this subject only by declaring `environment: infra-<env>`,
        # and GitHub issues the token only after that environment's rules pass:
        # deployment branch main, and for prod, a reviewer's approval. A pull
        # request cannot produce it, and neither can a push to another branch.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            for s in local.repo_subjects : "${s}:environment:infra-${each.key}"
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "tf_apply" {
  for_each = local.environments

  name = "apply-${each.key}"
  role = aws_iam_role.tf_apply[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # This environment's state and lock, and nothing else in the bucket.
        Sid    = "WriteOwnState"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [
          "arn:aws:s3:::${local.state_bucket}/envs/${each.key}/terraform.tfstate",
          "arn:aws:s3:::${local.state_bucket}/envs/${each.key}/terraform.tfstate.tflock",
        ]
      },
      {
        Sid      = "ListOwnState"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::${local.state_bucket}"]
        Condition = {
          StringLike = { "s3:prefix" = ["envs/${each.key}/*"] }
        }
      },
      {
        # Manage this environment's bucket: the five settings
        # modules/s3-bucket writes, and nothing else.
        #
        # The first version said s3:Put*, and policy/terraform/iam.rego
        # flagged it. Put* includes PutBucketPolicy and PutBucketAcl, the two
        # ways to make a bucket public. Without them, this role cannot make
        # the bucket public even if every other check is bypassed.
        # PutBucketPublicAccessBlock is here because the module sets it, so the
        # policy check in CI still has to stop a plan that sets a flag to false.
        Sid    = "ManageOwnBucket"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:Get*",
          "s3:List*",
          "s3:PutBucketTagging",
          "s3:PutBucketVersioning",
          "s3:PutEncryptionConfiguration",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutLifecycleConfiguration",
        ]
        Resource = ["arn:aws:s3:::ci-cd-lab-${each.key}-${local.account_id}"]
      },
    ]
  })
}
