# Secrets from SSM Parameter Store, through External Secrets. Project 17.
#
# The External Secrets controller is one pod serving every namespace, so its
# own credentials are shared by all of them. If its role could read
# /ci-cd-lab/*, an ExternalSecret in api-dev could ask for prod's values and
# get them. Two roles fix that:
#
#   eso_controller  the controller's Pod Identity role. It can do one thing:
#                   assume secrets_reader, with session tags.
#   secrets_reader  reads /ci-cd-lab/<namespace>/*, where <namespace> is the
#                   `esoNamespace` session tag. The controller sets that tag
#                   from the namespace of the ExternalSecret it is serving
#                   (`sessionTagsPolicy: Simple` on the ClusterSecretStore),
#                   so the namespace an ExternalSecret lives in decides what it
#                   can read, not the key it asks for.
#
# Nothing here holds a secret value. The parameters are created and rotated
# with `aws ssm put-parameter`: a value in Terraform is a value in the state
# file.

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_role" "eso_controller" {
  name                 = "${var.cluster_name}-eso-controller"
  permissions_boundary = aws_iam_policy.workload_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "eso_controller" {
  name = "assume-secrets-reader"
  role = aws_iam_role.eso_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sts:AssumeRole", "sts:TagSession"]
      Resource = aws_iam_role.secrets_reader.arn
    }]
  })
}

resource "aws_eks_pod_identity_association" "eso_controller" {
  cluster_name    = aws_eks_cluster.lab.name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso_controller.arn

  depends_on = [aws_eks_addon.pod_identity]
}

resource "aws_iam_role" "secrets_reader" {
  name                 = "${var.cluster_name}-secrets-reader"
  permissions_boundary = aws_iam_policy.workload_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${local.account_id}:role/${var.cluster_name}-eso-controller" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      # No condition on the tag here. A first version required
      # `aws:RequestTag/esoNamespace` to match api-*, and the store never
      # became Ready: External Secrets validates a ClusterSecretStore by
      # assuming the role outside any namespace, that call failed the
      # condition, and every ExternalSecret then refused to sync. The policy
      # below already reads only /ci-cd-lab/<tag>/*, and the store's
      # namespaceRegexes decide which namespaces may use it at all.
    }]
  })
}

resource "aws_iam_role_policy" "secrets_reader" {
  name = "ssm-own-namespace"
  role = aws_iam_role.secrets_reader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameter", "ssm:GetParameters"]
      # `$${...}` is Terraform's escape: IAM, not Terraform, fills in the tag
      # at request time. SecureString values are encrypted with the AWS
      # managed key aws/ssm, whose key policy already allows decryption
      # through SSM to anyone in the account allowed to read the parameter.
      Resource = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/ci-cd-lab/$${aws:PrincipalTag/esoNamespace}/*"
    }]
  })
}

# The permissions boundary: the most any workload role here can ever do,
# whatever policies are attached to it later. Effective permissions are the
# intersection of the role's policies and this. An `AdministratorAccess`
# attached during a 2 a.m. debugging session gives these roles nothing
# beyond what is listed here.
#
# It is not a grant. A role with this boundary and no policy can do nothing.
resource "aws_iam_policy" "workload_boundary" {
  name        = "${var.cluster_name}-workload-boundary"
  description = "Upper bound for the lab cluster's Pod Identity roles (Project 17)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "OrdersTables"
        Effect   = "Allow"
        Action   = ["dynamodb:*"]
        Resource = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${var.table_prefix}-*"
      },
      {
        Sid      = "LabParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/ci-cd-lab/*"
      },
      {
        Sid      = "SecretsReader"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole", "sts:TagSession"]
        Resource = "arn:aws:iam::${local.account_id}:role/${var.cluster_name}-secrets-reader"
      },
    ]
  })
}
