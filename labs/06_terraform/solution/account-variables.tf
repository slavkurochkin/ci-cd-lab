variable "region" {
  description = "S3 bucket names are global; the bucket itself lives in one region."
  type        = string
  default     = "us-east-1"
}

variable "budget_limit" {
  description = <<-DESC
    Monthly spend, in dollars, before the alert fires.

    This is a tripwire, not a cap. AWS does not stop anything when a budget is
    exceeded -- it sends an email. Treating it as a limit is the mistake that
    turns a forgotten cluster into a surprise.
  DESC
  type        = number
  default     = 50
}

variable "budget_email" {
  description = "Where the alert goes. No default: an alert nobody receives is not an alert."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[a-zA-Z]{2,}$", var.budget_email))
    error_message = "budget_email must be a single email address."
  }
}
