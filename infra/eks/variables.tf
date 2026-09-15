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
  description = "EKS control plane version."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "Node size. t3.medium is the smallest that comfortably runs the addons plus both services."
  type        = string
  default     = "t3.medium"
}

variable "node_count" {
  description = "Node count, fixed. Two is the minimum that makes a PodDisruptionBudget mean anything."
  type        = number
  default     = 2
}

variable "github_repo" {
  description = "owner/repo allowed to assume the CI deploy role. This is the only thing standing between your cluster and any other repository on GitHub -- do not widen it to a wildcard owner."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repo))
    error_message = "github_repo must be exactly owner/repo, with no wildcard and no leading https://github.com/."
  }
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

variable "ci_role_name" {
  description = <<-DESC
    Name of the CI role created by infra/ci-oidc. This stack looks it up and
    attaches cluster-scoped permissions to it; it does not create it. Apply
    infra/ci-oidc first or the data lookup fails.
  DESC
  type        = string
  default     = "ci-cd-lab-ci"
}
