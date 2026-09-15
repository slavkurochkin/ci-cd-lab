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

# GitHub now issues an "immutable" sub claim that embeds numeric IDs:
#
#   repo:owner@<owner_id>/name@<repo_id>:pull_request
#
# rather than the older repo:owner/name:pull_request. The IDs survive a rename
# or an ownership transfer, which is the whole point -- a trust policy pinned to
# names alone can be defeated by renaming a repository out from under it.
#
# Find yours with:
#
#   gh api repos/OWNER/NAME --jq '"repo \(.id), owner \(.owner.id)"'
#
variable "github_owner_id" {
  description = "Numeric GitHub account ID of the repository owner."
  type        = string
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID."
  type        = string
}
