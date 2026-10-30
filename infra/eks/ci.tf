# How the *deploy job* gets into the cluster.
#
# Two separate problems, and conflating them is the usual mistake:
#
#   1. Authentication to AWS -- GitHub OIDC. The provider lives in
#      infra/ci-oidc: an account holds exactly ONE OIDC provider per issuer
#      URL, and it must outlive any cluster. This stack looks it up.
#   2. Authorization in the cluster -- the access entry, below. Being able to
#      call `aws eks describe-cluster` does not let you create a Deployment.
#      An IAM principal with no access entry authenticates fine and then gets
#      `Unauthorized` from the API server, which reads like a broken token.
#
# A role of its own, not the shared CI role. The CI role (infra/ci-oidc)
# trusts the main branch and pushes images. This one trusts only jobs running
# in the `eks` GitHub environment, can describe one cluster, and can edit one
# namespace. It is created and destroyed with the cluster, so between sessions
# there is no deploy credential to misuse at all.

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  repo_owner = split("/", var.github_repo)[0]
  repo_name  = split("/", var.github_repo)[1]

  # Both spellings of the subject, as in infra/ci-oidc: GitHub is moving to
  # the form with numeric IDs, which survives a rename of the owner or repo.
  deploy_subjects = [
    "repo:${var.github_repo}:environment:${var.deploy_environment}",
    "repo:${local.repo_owner}@${var.github_owner_id}/${local.repo_name}@${var.github_repo_id}:environment:${var.deploy_environment}",
  ]
}

resource "aws_iam_role" "deploy" {
  name        = "${var.cluster_name}-eks-deploy"
  description = "Assumed by the deploy job in ${var.github_repo}, environment ${var.deploy_environment}, via OIDC."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # StringEquals, not StringLike: exact subjects, no wildcard. A job
          # with `environment: eks` presents this subject instead of its
          # branch, which is why the shared CI role (main and v* tags only)
          # could not be used here.
          "token.actions.githubusercontent.com:sub" = local.deploy_subjects
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "deploy" {
  name = "eks-describe"
  role = aws_iam_role.deploy.id

  # `aws eks update-kubeconfig` needs this one call. Everything after it is
  # Kubernetes RBAC, granted by the access entry.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = aws_eks_cluster.lab.arn
    }]
  })
}

resource "aws_eks_access_entry" "deploy" {
  cluster_name  = aws_eks_cluster.lab.name
  principal_arn = aws_iam_role.deploy.arn
  type          = "STANDARD"
}

# Edit, not admin, and one namespace. CI can roll out the api and cannot touch
# kube-system, other namespaces, or anything cluster-scoped -- including
# creating its own namespace, which `make eks-up` does instead.
resource "aws_eks_access_policy_association" "deploy" {
  cluster_name  = aws_eks_cluster.lab.name
  principal_arn = aws_iam_role.deploy.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [var.app_namespace]
  }

  depends_on = [aws_eks_access_entry.deploy]
}
