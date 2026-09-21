variable "region" {
  description = "Must match where EKS runs -- a pull across regions costs egress and adds latency."
  type        = string
  default     = "us-east-1"
}

variable "services" {
  description = "One repository per service. Adding a service here is the only infrastructure change a new service needs."
  type        = list(string)
  default     = ["api", "worker"]
}

variable "retained_images" {
  description = <<-DESC
    How many tagged images to keep per repository.

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
