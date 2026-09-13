# How the *runner* gets AWS credentials, and then cluster credentials.
#
# Two separate problems, and conflating them is the usual mistake:
#
#   1. Authentication to AWS  -- GitHub OIDC, below. The runner presents a token
#      GitHub signed, AWS verifies it against the OIDC provider, and hands back
#      short-lived STS credentials. No access key exists in GitHub secrets.
#   2. Authorization in the cluster -- the access entry, below. Being able to
#      call `aws eks describe-cluster` does not let you create a Deployment.
#      An IAM principal with no access entry authenticates fine and then gets
#      `Unauthorized` from the API server, which reads like a broken token.

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # `sts.amazonaws.com` is the audience aws-actions/configure-aws-credentials
  # requests. A mismatch here is a silent no-match on the trust policy.
  client_id_list = ["sts.amazonaws.com"]

  # AWS stopped verifying this thumbprint for the GitHub issuer, but the API
  # still requires the field. It is vestigial, not load-bearing -- do not build
  # a rotation runbook around it.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "ci_deploy" {
  name = "${var.cluster_name}-ci-deploy"

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
        # The `sub` condition is the whole security boundary. Omit it and any
        # repository on GitHub can assume this role. Widen it to `repo:owner/*`
        # and any repo you own can, including one you fork in five years.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
        }
      }
    }]
  })
}

# Enough to fetch a kubeconfig, and nothing else. The cluster permissions come
# from the access entry below, not from IAM.
resource "aws_iam_role_policy" "ci_deploy" {
  name = "eks-describe"
  role = aws_iam_role.ci_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = aws_eks_cluster.lab.arn
    }]
  })
}

resource "aws_eks_access_entry" "ci_deploy" {
  cluster_name  = aws_eks_cluster.lab.name
  principal_arn = aws_iam_role.ci_deploy.arn
  type          = "STANDARD"
}

# Edit, not admin, and scoped to one namespace. CI can roll out a Deployment and
# cannot delete the cluster's system components -- which matters on the day a
# workflow does exactly what you told it to, to the wrong namespace.
resource "aws_eks_access_policy_association" "ci_deploy" {
  cluster_name  = aws_eks_cluster.lab.name
  principal_arn = aws_iam_role.ci_deploy.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["default"]
  }

  depends_on = [aws_eks_access_entry.ci_deploy]
}
