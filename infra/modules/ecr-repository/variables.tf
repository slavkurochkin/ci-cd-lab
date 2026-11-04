variable "name" {
  description = "Repository name, e.g. `ci-cd-lab/api`. Lowercase, and slashes for namespaces."
  type        = string

  validation {
    # ECR's own rule. Checking it here fails at plan, on your laptop, instead
    # of at apply with an API error halfway through.
    condition     = can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$", var.name)) && length(var.name) >= 2 && length(var.name) <= 256
    error_message = "name must be 2-256 characters of lowercase letters, digits, and . _ - /, starting and ending each part with a letter or digit."
  }
}

variable "retained_images" {
  description = "Tagged images to keep. Older ones expire. This is what keeps storage inside the free tier."
  type        = number
  default     = 10

  validation {
    condition     = var.retained_images >= 1 && var.retained_images <= 1000 && floor(var.retained_images) == var.retained_images
    error_message = "retained_images must be a whole number from 1 to 1000. Zero would expire every image, including the one running."
  }
}

variable "retained_releases" {
  description = "Release images to keep, matched by a semver tag such as `0.2.0`. Environments run these, so they must outlive ordinary builds."
  type        = number
  default     = 20

  validation {
    condition     = var.retained_releases >= 1 && floor(var.retained_releases) == var.retained_releases
    error_message = "retained_releases must be a whole number of at least 1."
  }
}

variable "untagged_expiry_days" {
  description = "Days before an untagged image expires. Untagged images are layers left behind by a retag, and nothing pulls them."
  type        = number
  default     = 1

  validation {
    condition     = var.untagged_expiry_days >= 1 && floor(var.untagged_expiry_days) == var.untagged_expiry_days
    error_message = "untagged_expiry_days must be a whole number of at least 1."
  }
}

variable "immutable_tags" {
  description = "Refuse to push a tag that already exists. Leave this on unless you have a reason a tag should change meaning."
  type        = bool
  default     = true
}

variable "scan_on_push" {
  description = "Run ECR basic scanning on every push."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags for the repository. Provider `default_tags` still apply."
  type        = map(string)
  default     = {}
}

variable "lambda_pull_source_arns" {
  description = "Lambda function ARNs (wildcards allowed) that may pull from this repository. Empty: no repository policy."
  type        = list(string)
  default     = []
}
