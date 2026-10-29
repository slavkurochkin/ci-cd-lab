# Roles for Terraform in CI. Project 9, widened for Capstone B.
#
#   ci-cd-lab-tf-plan           read-only. Pull requests and main may assume it.
#   ci-cd-lab-tf-apply-nonprod  writes every environment except prod: dev,
#                               staging, and any environment added later.
#   ci-cd-lab-tf-apply-prod     writes prod only, after a person approves.
#
# Project 9 had one apply role per environment. Capstone B needs "a second
# environment is one pull request", and a role per environment would mean a
# laptop IAM change for every new one. So roles are per *tier*: what nonprod
# may touch is defined by name, and prod is carved out of it explicitly.
#
# CI applies infra/envs/* only. The stacks that write IAM broadly (ci-oidc,
# ecr) are still applied from a laptop. The one IAM thing CI may now do --
# create the function's execution role -- is fenced by a permissions boundary,
# below.

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  region       = "us-east-1"
  state_bucket = "ci-cd-lab-tfstate-${local.account_id}"

  # Both spellings of the repository, for the reason given on the CI role's
  # trust policy in main.tf.
  repo_subjects = [
    "repo:${var.github_repo}",
    "repo:${local.owner}@${var.github_owner_id}/${local.name}@${var.github_repo_id}",
  ]

  # `env` is the part of every resource name that says which environment it
  # belongs to: ci-cd-lab-<env>-api, ci-cd-lab-<env>-orders, and so on.
  # nonprod matches any env, then prod is denied separately.
  tiers = {
    nonprod = { env = "*", subjects = [for s in local.repo_subjects : "${s}:environment:infra-*"] }
    prod    = { env = "prod", subjects = [for s in local.repo_subjects : "${s}:environment:infra-prod"] }
  }

  # Names that look like an environment's but are not: `ci-cd-lab-*` would
  # otherwise match the state bucket and the artifacts bucket.
  never_env_buckets = [
    "arn:aws:s3:::${local.state_bucket}",
    "arn:aws:s3:::${local.state_bucket}/*",
    "arn:aws:s3:::ci-cd-lab-artifacts-${local.account_id}",
    "arn:aws:s3:::ci-cd-lab-artifacts-${local.account_id}/*",
  ]

  boundary_arn = "arn:aws:iam::${local.account_id}:policy/ci-cd-lab-lambda-boundary"
}

# ---------------------------------------------------------------------------
# The permissions boundary
# ---------------------------------------------------------------------------
#
# The answer to "the apply role must create IAM roles without being able to
# escalate itself". The apply role may create a role only if this boundary is
# attached, and may not remove it or edit it. A role's effective permissions
# are the intersection of its own policy and its boundary, so whatever inline
# policy the apply role writes onto a role, that role can never do more than
# this: write function logs and read and write an orders table. No IAM, no STS,
# nothing else.

resource "aws_iam_policy" "lambda_boundary" {
  name        = "ci-cd-lab-lambda-boundary"
  description = "Ceiling for every role CI creates. Logs and orders tables only."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "FunctionLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/ci-cd-lab-*:*"]
      },
      {
        Sid      = "OrdersTables"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
        Resource = ["arn:aws:dynamodb:${local.region}:${local.account_id}:table/ci-cd-lab-*-orders"]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Plan: read-only
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
        # Pull requests, and main for the nightly drift check. Safe only
        # because nothing below writes to a resource.
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
        # text, so reading ci-oidc's or account's would be reading more than a
        # plan of an environment needs.
        Sid      = "ReadEnvState"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["arn:aws:s3:::${local.state_bucket}/envs/*/terraform.tfstate"]
      },
      {
        Sid       = "ListEnvState"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = ["arn:aws:s3:::${local.state_bucket}"]
        Condition = { StringLike = { "s3:prefix" = ["envs/*"] } }
      },
      {
        # plan takes the lock too. GetObject because releasing the lock reads
        # it back first; Project 9's first run lacked it and left both
        # environments locked.
        Sid      = "LockEnvState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["arn:aws:s3:::${local.state_bucket}/envs/*/terraform.tfstate.tflock"]
      },
      {
        # Refreshing reads every setting of every resource. Get/List/Describe
        # only, on environment-named resources only.
        Sid    = "RefreshEnvResources"
        Effect = "Allow"
        Action = [
          "s3:Get*", "s3:List*",
          "dynamodb:Describe*", "dynamodb:List*",
          "lambda:Get*", "lambda:List*",
          "logs:Describe*", "logs:List*",
          "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "ecr:DescribeRepositories", "ecr:ListTagsForResource",
        ]
        Resource = [
          "arn:aws:s3:::ci-cd-lab-*-${local.account_id}",
          "arn:aws:dynamodb:${local.region}:${local.account_id}:table/ci-cd-lab-*-orders",
          "arn:aws:lambda:${local.region}:${local.account_id}:function:ci-cd-lab-*-api",
          "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/ci-cd-lab-*",
          "arn:aws:iam::${local.account_id}:role/ci-cd-lab-*-api-lambda",
          "arn:aws:ecr:${local.region}:${local.account_id}:repository/ci-cd-lab/api",
        ]
      },
      {
        # Reads that exist only at account level.
        Sid      = "AccountLevelReads"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups", "apigateway:GET"]
        Resource = ["*"]
      },
    ]
  })
}

# Statements only one tier gets. nonprod's `*` matches prod's names too, so
# nonprod is denied them outright.
locals {
  tier_denies = {
    prod = []
    nonprod = [
      {
        Sid    = "NeverProd"
        Effect = "Deny"
        Action = ["s3:*", "dynamodb:*", "lambda:*", "logs:*", "iam:*"]
        Resource = [
          "arn:aws:s3:::ci-cd-lab-prod-${local.account_id}",
          "arn:aws:s3:::${local.state_bucket}/envs/prod/*",
          "arn:aws:dynamodb:${local.region}:${local.account_id}:table/ci-cd-lab-prod-orders",
          "arn:aws:lambda:${local.region}:${local.account_id}:function:ci-cd-lab-prod-api",
          "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/ci-cd-lab-prod-api*",
          "arn:aws:iam::${local.account_id}:role/ci-cd-lab-prod-api-lambda",
        ]
      },
      {
        Sid       = "NeverProdApi"
        Effect    = "Deny"
        Action    = ["apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE"]
        Resource  = ["*"]
        Condition = { StringEquals = { "aws:ResourceTag/Environment" = "prod" } }
      },
    ]
  }
}

# ---------------------------------------------------------------------------
# Apply: one role per tier
# ---------------------------------------------------------------------------

resource "aws_iam_role" "tf_apply" {
  for_each = local.tiers

  name        = "ci-cd-lab-tf-apply-${each.key}"
  description = "Terraform apply for infra/envs, ${each.key} tier. Only from an infra-* GitHub environment."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = merge(
        {
          StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
          StringLike   = { "token.actions.githubusercontent.com:sub" = each.value.subjects }
        },
        # infra-* would include infra-prod. Excluded here, so the only way to
        # the prod tier is the prod environment and its required reviewer.
        each.key == "nonprod" ? {
          StringNotLike = {
            "token.actions.githubusercontent.com:sub" = [for s in local.repo_subjects : "${s}:environment:infra-prod"]
          }
        } : {},
      )
    }]
  })
}

resource "aws_iam_role_policy" "tf_apply" {
  for_each = local.tiers

  name = "apply-${each.key}"
  role = aws_iam_role.tf_apply[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "WriteState"
          Effect = "Allow"
          Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = [
            "arn:aws:s3:::${local.state_bucket}/envs/${each.value.env}/terraform.tfstate",
            "arn:aws:s3:::${local.state_bucket}/envs/${each.value.env}/terraform.tfstate.tflock",
          ]
        },
        {
          Sid       = "ListState"
          Effect    = "Allow"
          Action    = ["s3:ListBucket"]
          Resource  = ["arn:aws:s3:::${local.state_bucket}"]
          Condition = { StringLike = { "s3:prefix" = ["envs/${each.value.env}/*"] } }
        },
        {
          # The five settings modules/s3-bucket writes, and no route to
          # public: no PutBucketPolicy, no PutBucketAcl.
          Sid    = "EnvBuckets"
          Effect = "Allow"
          Action = [
            "s3:CreateBucket", "s3:DeleteBucket", "s3:Get*", "s3:List*",
            "s3:PutBucketTagging", "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration",
            "s3:PutBucketPublicAccessBlock", "s3:PutLifecycleConfiguration",
          ]
          Resource = ["arn:aws:s3:::ci-cd-lab-${each.value.env}-${local.account_id}"]
        },
        {
          Sid    = "OrdersTable"
          Effect = "Allow"
          Action = [
            "dynamodb:CreateTable", "dynamodb:DeleteTable", "dynamodb:UpdateTable",
            "dynamodb:TagResource", "dynamodb:UntagResource", "dynamodb:Describe*", "dynamodb:List*",
            "dynamodb:UpdateContinuousBackups", "dynamodb:UpdateTimeToLive",
          ]
          Resource = ["arn:aws:dynamodb:${local.region}:${local.account_id}:table/ci-cd-lab-${each.value.env}-orders"]
        },
        {
          Sid    = "Function"
          Effect = "Allow"
          Action = [
            "lambda:CreateFunction", "lambda:DeleteFunction",
            "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration",
            "lambda:AddPermission", "lambda:RemovePermission",
            "lambda:TagResource", "lambda:UntagResource", "lambda:Get*", "lambda:List*",
          ]
          Resource = ["arn:aws:lambda:${local.region}:${local.account_id}:function:ci-cd-lab-${each.value.env}-api"]
        },
        {
          # Lambda pulls the image as the principal creating or updating the
          # function, from this repository only.
          Sid      = "PullApiImage"
          Effect   = "Allow"
          Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeRepositories", "ecr:ListTagsForResource"]
          Resource = ["arn:aws:ecr:${local.region}:${local.account_id}:repository/ci-cd-lab/api"]
        },
        {
          Sid    = "FunctionLogGroup"
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy",
            "logs:TagResource", "logs:UntagResource", "logs:TagLogGroup", "logs:Describe*", "logs:List*",
          ]
          Resource = [
            "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/ci-cd-lab-${each.value.env}-api",
            "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/ci-cd-lab-${each.value.env}-api:*",
          ]
        },
        {
          Sid      = "AccountLevelReads"
          Effect   = "Allow"
          Action   = ["logs:DescribeLogGroups"]
          Resource = ["*"]
        },
        {
          # API Gateway resources are named by generated IDs, so they cannot
          # be scoped by name like everything above. See the Deny below and
          # docs/CAPSTONE-B.md for what that leaves open.
          Sid    = "HttpApi"
          Effect = "Allow"
          Action = ["apigateway:GET", "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE"]
          Resource = [
            "arn:aws:apigateway:${local.region}::/apis",
            "arn:aws:apigateway:${local.region}::/apis/*",
            "arn:aws:apigateway:${local.region}::/tags/*",
          ]
        },
        # --- Creating the function's role, inside the boundary -------------
        {
          # Only with the boundary attached. CreateRole without it, or with a
          # different policy as boundary, is AccessDenied.
          Sid       = "CreateBoundedRole"
          Effect    = "Allow"
          Action    = ["iam:CreateRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:UpdateAssumeRolePolicy"]
          Resource  = ["arn:aws:iam::${local.account_id}:role/ci-cd-lab-${each.value.env}-api-lambda"]
          Condition = { StringEquals = { "iam:PermissionsBoundary" = local.boundary_arn } }
        },
        {
          Sid    = "ManageBoundedRole"
          Effect = "Allow"
          Action = [
            "iam:GetRole", "iam:DeleteRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateRoleDescription",
            "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
            "iam:ListInstanceProfilesForRole",
          ]
          Resource = ["arn:aws:iam::${local.account_id}:role/ci-cd-lab-${each.value.env}-api-lambda"]
        },
        {
          Sid       = "PassRoleToLambdaOnly"
          Effect    = "Allow"
          Action    = ["iam:PassRole"]
          Resource  = ["arn:aws:iam::${local.account_id}:role/ci-cd-lab-${each.value.env}-api-lambda"]
          Condition = { StringEquals = { "iam:PassedToService" = "lambda.amazonaws.com" } }
        },
        {
          # Explicit denies win over any allow, including one added by mistake
          # later. The boundary cannot be removed, swapped or rewritten.
          Sid    = "BoundaryIsFixed"
          Effect = "Deny"
          Action = [
            "iam:DeleteRolePermissionsBoundary", "iam:PutRolePermissionsBoundary",
            "iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion",
          ]
          Resource = ["*"]
        },
        {
          Sid      = "NeverStateOrArtifacts"
          Effect   = "Deny"
          Action   = ["s3:DeleteBucket", "s3:PutBucket*", "s3:PutLifecycleConfiguration", "s3:PutEncryptionConfiguration", "s3:PutBucketPublicAccessBlock"]
          Resource = local.never_env_buckets
        },
      ],
      local.tier_denies[each.key],
    )
  })
}
