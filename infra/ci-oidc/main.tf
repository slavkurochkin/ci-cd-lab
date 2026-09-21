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
        # Narrowed when infra/ecr gave this role its first real permission.
        #
        # It used to end in `:*`, which was defensible while the role granted
        # nothing but its own identity. `:*` includes `:pull_request`, and a
        # pull_request subject names the repository the pull request targets --
        # not whoever wrote the code. Anyone able to open a pull request
        # matched it. With ECR push attached, that would have been anyone able
        # to open a pull request being able to push an image.
        #
        # Now: the default branch, and version tags for releases. Nothing else.
        #
        # Both spellings of each are listed because GitHub is moving from the
        # first form to the second, and a StringLike list matches if ANY entry
        # matches. The immutable form embedding numeric IDs is the one actually
        # presented today -- see the github_owner_id / github_repo_id variables
        # for why it exists.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:${var.github_repo}:ref:refs/heads/main",
            "repo:${var.github_repo}:ref:refs/tags/v*",
            "repo:${local.owner}@${var.github_owner_id}/${local.name}@${var.github_repo_id}:ref:refs/heads/main",
            "repo:${local.owner}@${var.github_owner_id}/${local.name}@${var.github_repo_id}:ref:refs/tags/v*",
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
