resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# These three are the documented minimum. AmazonEKS_CNI_Policy is the one people
# drop when tidying up, and the symptom is pods stuck ContainerCreating with a
# "failed to assign an IP address" event -- which reads like a subnet problem.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.lab.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id

  # Amazon Linux 2 has no EKS AMI for Kubernetes 1.33 and later. Named here
  # so the node group does not depend on the provider's default.
  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = [var.node_instance_type]
  capacity_type  = "ON_DEMAND"

  # The disk size moved into the launch template; EKS refuses both.
  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  # Fixed size, not a range. Autoscaling is Project 18's subject, and a cluster
  # that quietly grows a third node is a cluster that quietly grows a third bill.
  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_count
  }

  update_config {
    max_unavailable = 1
  }

  # Same reasoning as the cluster role: policies must outlive the node group.
  depends_on = [aws_iam_role_policy_attachment.node]
}

# Tags for what the node group launches (Project 18). Without a launch
# template, a managed node group's instances, root volumes and network
# interfaces carry only the AWS-generated eks:* tags, not the provider's
# default_tags. Their cost (EC2 compute, EBS, the public IPv4 addresses) then
# lands in the cost report's untagged row: about a third of a session's bill.
data "aws_default_tags" "current" {}

resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-node-"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  dynamic "tag_specifications" {
    for_each = ["instance", "volume", "network-interface"]
    content {
      resource_type = tag_specifications.value
      tags          = data.aws_default_tags.current.tags
    }
  }
}
