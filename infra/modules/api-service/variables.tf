variable "name_prefix" {
  description = "Prefix for every resource name, e.g. `ci-cd-lab-dev`. The CI apply roles are scoped to names that start with `ci-cd-lab-`."
  type        = string

  validation {
    condition     = can(regex("^ci-cd-lab-[a-z0-9]+$", var.name_prefix))
    error_message = "name_prefix must look like ci-cd-lab-<env>. The apply roles' permissions match that pattern, so any other name fails at apply with AccessDenied."
  }
}

variable "environment" {
  description = "Environment name. Reported by /version and passed to the function as ENVIRONMENT."
  type        = string
}

variable "image_digest" {
  description = "Digest of the **platform manifest** to run, `sha256:...`. Not the image index: Lambda rejects an index. See README.md."
  type        = string

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.image_digest))
    error_message = "image_digest must be sha256: followed by 64 hex characters. A tag is not accepted: tags move, and what runs must be visible in the plan."
  }
}

variable "repository_name" {
  description = "ECR repository holding the image."
  type        = string
  default     = "ci-cd-lab/api"
}

variable "permissions_boundary_arn" {
  description = "Boundary attached to the function's role. Required: the CI apply roles can only create roles that carry it."
  type        = string
}

variable "memory_size" {
  description = "Function memory in MB. CPU scales with it."
  type        = number
  default     = 512
}

variable "timeout" {
  description = "Function timeout in seconds."
  type        = number
  default     = 10
}

variable "log_retention_days" {
  description = "Days to keep function logs. A log group without retention keeps logs, and bills for them, forever."
  type        = number
  default     = 7
}

variable "throttle_rate_limit" {
  description = "Steady-state requests per second the API accepts. The cost guard: past it, API Gateway answers 429 and nothing behind it runs."
  type        = number
  default     = 5
}

variable "throttle_burst_limit" {
  description = "Requests the API accepts in a burst above the rate limit."
  type        = number
  default     = 10
}
