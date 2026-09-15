# How the *runner* gets cluster credentials.
#
# Two separate problems, and conflating them is the usual mistake:
#
#   1. Authentication to AWS -- GitHub OIDC. That lives in infra/ci-oidc, not
#      here. An AWS account holds exactly ONE OIDC provider per issuer URL, so
#      creating it in this stack would fail the moment any other stack needed
#      it, and would destroy the trust relationship every time the cluster came
#      down. The provider and the role outlive any cluster.
#   2. Authorization in the cluster -- the access entry, below. Being able to
#      call `aws eks describe-cluster` does not let you create a Deployment.
#      An IAM principal with no access entry authenticates fine and then gets
#      `Unauthorized` from the API server, which reads like a broken token.
#
# This file does only the second. It looks the role up and attaches
# cluster-scoped permissions to it.

data "aws_iam_role" "ci" {
  name = var.ci_role_name
}

resource "aws_iam_role_policy" "ci_deploy" {
  name = "eks-describe"
  role = data.aws_iam_role.ci.name

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
  principal_arn = data.aws_iam_role.ci.arn
  type          = "STANDARD"
}

# Edit, not admin, and scoped to one namespace. CI can roll out a Deployment and
# cannot delete the cluster's system components -- which matters on the day a
# workflow does exactly what you told it to, to the wrong namespace.
resource "aws_eks_access_policy_association" "ci_deploy" {
  cluster_name  = aws_eks_cluster.lab.name
  principal_arn = data.aws_iam_role.ci.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["default"]
  }

  depends_on = [aws_eks_access_entry.ci_deploy]
}
