variable "region" {
  description = "Must match where EKS runs -- a pull across regions costs egress and adds latency."
  type        = string
  default     = "us-east-1"
}

variable "services" {
  description = <<-DESC
    One repository per service, keyed by service name. Adding a service is one
    line: `newservice = {}`. Set retained_images to override the default for
    that service only.
  DESC
  type = map(object({
    retained_images = optional(number)
    lambda_pull     = optional(bool, false)
  }))
  default = {
    api    = { lambda_pull = true }
    worker = {}
  }
}

variable "retained_images" {
  description = <<-DESC
    How many tagged images to keep per repository, unless a service overrides it.

    This is the only thing standing between a per-merge push and an unbounded
    storage bill. Ten is enough to roll back several releases and small enough
    that the total stays inside the free tier.
  DESC
  type        = number
  default     = 10
}

variable "ci_role_name" {
  description = "The role created by infra/ci-oidc. This stack grants it push access; it does not create it."
  type        = string
  default     = "ci-cd-lab-ci"
}
