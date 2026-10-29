# Capstone B: pull public images authenticated, from any build including PRs.
#
# The api image copies the Lambda Web Adapter from ECR Public. Anonymous pulls
# get 1 per second and 500 GB a month, shared with every other GitHub runner
# behind the same IP. Pull request builds failed with
# `toomanyrequests: Data limit exceeded` three times, the last two in a row.
#
# This role can do one thing: get an ECR Public login token. That token pulls
# public images, which anyone can already pull anonymously, so a pull request
# assuming it gains rate limit, not access.

resource "aws_iam_role" "public_pull" {
  name        = "ci-cd-lab-public-pull"
  description = "Authenticated pulls from ECR Public for any build of this repository. Grants nothing private."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = flatten([
            for s in local.repo_subjects : ["${s}:pull_request", "${s}:ref:refs/heads/main", "${s}:ref:refs/tags/v*"]
          ])
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "public_pull" {
  name = "ecr-public-login"
  role = aws_iam_role.public_pull.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # Account-level token actions; there is no resource to scope them to.
      Sid      = "EcrPublicLogin"
      Effect   = "Allow"
      Action   = ["ecr-public:GetAuthorizationToken", "sts:GetServiceBearerToken"]
      Resource = "*"
    }]
  })
}
