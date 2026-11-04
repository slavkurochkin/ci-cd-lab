variable "name" {
  description = "Bucket name. Globally unique across every AWS account, so include the account ID."
  type        = string
}

variable "noncurrent_days" {
  description = "Days an overwritten or deleted object version is kept before it expires."
  type        = number
  default     = 30
}
