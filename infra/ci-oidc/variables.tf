variable "region" {
  description = "IAM is global, but the provider still needs a region. Match AWS_LAB_REGION."
  type        = string
  default     = "us-east-1"
}

variable "github_repo" {
  description = <<-DESC
    owner/name of the repository allowed to assume the CI role.

    This is the security boundary. Widen it to a wildcard owner and every
    repository you own -- including one you fork in five years -- can assume
    this role. It has no default on purpose.
  DESC
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repo))
    error_message = "github_repo must be exactly owner/name, with no wildcards."
  }
}

variable "role_name" {
  description = "Name of the CI role. infra/eks looks this up by name to attach cluster permissions."
  type        = string
  default     = "ci-cd-lab-ci"
}
