# Credential-free AWS access for GitHub Actions.
#
# This stack costs nothing and is meant to stay applied. Everything in it is
# account-level and long-lived, which is precisely why it does not belong in
# infra/eks: an AWS account may hold exactly ONE OIDC provider per issuer URL,
# so a second stack trying to create this one fails with EntityAlreadyExists.
# The cluster lives for a session; this trust relationship lives for years.

# GitHub's token issuer, registered once for the whole account.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # The audience aws-actions/configure-aws-credentials requests. A mismatch
  # here is a silent no-match against the trust policy below -- the role simply
  # cannot be assumed, with no clue as to why.
  client_id_list = ["sts.amazonaws.com"]

  # AWS stopped verifying this thumbprint for the GitHub issuer, but the API
  # still requires the field. It is left over and checks nothing -- do not
  # build a rotation runbook around it.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  owner = split("/", var.github_repo)[0]
  name  = split("/", var.github_repo)[1]
}

resource "aws_iam_role" "ci" {
  name        = var.role_name
  description = "Assumed by GitHub Actions in ${var.github_repo} via OIDC. No access key exists."

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
        # The whole security boundary is this one line.
        #
        # Omit it and ANY repository on GitHub can assume this role. Widen it
        # to `repo:owner/*` and any repo you own can, including a fork you
        # create years from now and forget about.
        #
        # The trailing `:*` allows any branch, tag and pull request. That is
        # deliberate while the role grants nothing but its own identity -- you
        # want this working from feature branches throughout Track B. Narrow it
        # to `:ref:refs/heads/main` before attaching any policy that can change
        # infrastructure.
        #
        # Both spellings are listed because GitHub is moving from the first to
        # the second, and a StringLike list matches if ANY entry matches. The
        # immutable form is the one actually presented today -- see the
        # github_owner_id / github_repo_id variables for why it exists.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:${var.github_repo}:*",
            "repo:${local.owner}@${var.github_owner_id}/${local.name}@${var.github_repo_id}:*",
          ]
        }
      }
    }]
  })
}

# No policies attached, on purpose.
#
# sts:GetCallerIdentity needs no permission -- every principal can ask who it
# is. So this role proves AUTHENTICATION works while granting no
# AUTHORIZATION at all, which is the smallest thing that can demonstrate OIDC
# and the safest thing to leave applied indefinitely.
#
# Project 6 attaches Terraform permissions when there is something to manage.
# infra/eks attaches its own cluster-scoped policy to this role by name.
