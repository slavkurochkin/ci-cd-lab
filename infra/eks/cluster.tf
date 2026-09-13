resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "lab" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  # `API` is the modern authorization mode: IAM principals are granted cluster
  # access through aws_eks_access_entry resources, in Terraform, reviewable in a
  # diff. The alternative you will meet in every older cluster is the aws-auth
  # ConfigMap -- a single YAML blob, edited in place, with no history and one
  # well-known way to lock yourself out of your own cluster permanently.
  access_config {
    authentication_mode = "API"

    # Grants the identity running `terraform apply` cluster-admin. That is you,
    # on your laptop. CI gets its own scoped entry in ci.tf and is not an admin.
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Without this the role can lose its policy before the cluster finishes
  # deleting, and the delete fails in a way that needs console surgery.
  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# --- Addons ----------------------------------------------------------------
# vpc-cni and kube-proxy run before nodes exist. coredns schedules onto nodes,
# so it waits for them -- install it early and it sits Pending and the cluster
# looks broken while being entirely fine.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.lab.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.lab.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.lab.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"

  depends_on = [aws_eks_node_group.default]
}

# The agent that makes Pod Identity work at all. Without it, a pod with a
# perfectly correct association gets no credentials and the SDK reports the
# generic "unable to locate credentials" -- with nothing pointing here.
resource "aws_eks_addon" "pod_identity" {
  cluster_name                = aws_eks_cluster.lab.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
}
