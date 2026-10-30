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

variable "github_owner_id" {
  description = "Numeric GitHub account ID of the repository owner. Same value as infra/ci-oidc."
  type        = string
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID. Same value as infra/ci-oidc."
  type        = string
}

variable "deploy_environment" {
  description = "GitHub environment the deploy job runs in. The deploy role trusts this environment and nothing else."
  type        = string
  default     = "eks"
}

variable "app_namespace" {
  description = "Namespace the api runs in. CI may edit this namespace and no other; Pod Identity binds the api's ServiceAccount here."
  type        = string
  default     = "lab"
}
