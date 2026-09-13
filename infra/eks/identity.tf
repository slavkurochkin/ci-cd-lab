# How a *pod* gets AWS credentials.
#
# The shape to notice: nothing here is a secret, and nothing here is mounted
# into the pod by you. The association binds a ServiceAccount to an IAM role;
# the pod identity agent exchanges the pod's projected token for short-lived STS
# credentials; the SDK inside the container picks them up with no configuration.
# There is no key to rotate because there is no key.
#
# This is the half a secrets manager cannot do for you. Doppler (Project 11)
# holds application secrets -- a third-party API key, a webhook URL. Put an AWS
# access key in it and you have reintroduced exactly the long-lived credential
# this file exists to delete, and now it lives in two places instead of one.

resource "aws_dynamodb_table" "orders" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST" # on-demand: no idle cost, inside the always-free tier
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }
}

resource "aws_iam_role" "api_pod" {
  name = "${var.cluster_name}-api-pod"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }

      # sts:TagSession is not optional here. Pod Identity always tags the
      # session with the cluster and namespace, so a trust policy that allows
      # only sts:AssumeRole fails with AccessDenied and an error message that
      # does not mention tagging at all.
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "api_pod" {
  name = "dynamodb-orders"
  role = aws_iam_role.api_pod.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:Query",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
      ]
      # One table, by ARN. Not "dynamodb:*" on "*", which is what this becomes
      # the first time someone debugs a permissions error in a hurry.
      Resource = aws_dynamodb_table.orders.arn
    }]
  })
}

# The binding itself. Note what it keys on: a namespace and a ServiceAccount
# name, both strings. Nothing validates that the ServiceAccount exists -- create
# the association for `api` and deploy a pod using `default` and you get no
# error anywhere, just a pod with no credentials. Same failure shape as a
# mistyped label selector, and diagnosed the same way: check what actually
# matched, not what you meant to match.
resource "aws_eks_pod_identity_association" "api" {
  cluster_name    = aws_eks_cluster.lab.name
  namespace       = "default"
  service_account = "api"
  role_arn        = aws_iam_role.api_pod.arn

  depends_on = [aws_eks_addon.pod_identity]
}
