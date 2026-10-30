variable "region" {
  description = "The single pinned lab region. One region means one place to sweep."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Cluster name. `make eks-up` runs `aws eks update-kubeconfig --name lab`, so changing this means changing that too."
  type        = string
  default     = "lab"
}

variable "kubernetes_version" {
  description = <<-DESC
    EKS control plane version. Keep it in standard support: a version past its
    standard-support date moves to extended support, which bills the control
    plane at $0.60/hr instead of $0.10, with no other change. 1.31 was the
    default here until Project 13 found it already in extended support.
    Check with `aws eks describe-cluster-versions`.
  DESC
  type        = string
  default     = "1.35"
}

variable "node_instance_type" {
  description = <<-DESC
    Node size. t3.small: 2 vCPU, 2 GiB, up to 11 pods (3 ENIs x 4 IPs). The
    system pods that use pod IPs are coredns and little else, so that is room
    for the api with plenty to spare.

    It was t3.medium. An account on AWS's free plan may only launch
    free-tier-eligible types, and the node group sat in CREATING for 25
    minutes while every launch failed with "The specified instance type is
    not eligible for Free Tier" -- visible only in the Auto Scaling group's
    activity history, not in the node group's health. List the allowed types:
      aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true
  DESC
  type        = string
  default     = "t3.small"
}

variable "node_count" {
  description = "Node count, fixed. Two is the minimum that makes a PodDisruptionBudget mean anything."
  type        = number
  default     = 2
}

variable "vpc_cidr" {
  description = "CIDR for the lab VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "table_name" {
  description = "DynamoDB table the API reads through Pod Identity. On-demand billing, inside the always-free tier."
  type        = string
  default     = "lab-orders"
}

variable "app_namespaces" {
  description = <<-DESC
    Namespaces the api runs in, one per environment. Argo CD creates them
    (Project 14); Pod Identity binds the api's ServiceAccount in each.
  DESC
  type        = list(string)
  default     = ["api-dev", "api-staging"]
}
