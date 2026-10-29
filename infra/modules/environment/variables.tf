variable "environment" {
  description = "Environment name: dev, staging, prod. Every resource name is built from it."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.environment))
    error_message = "environment must be lowercase letters and digits. It becomes part of bucket, table and function names."
  }
}

variable "api_image_digest" {
  description = "Platform manifest digest of the api image to run. See modules/api-service."
  type        = string
}

variable "data_noncurrent_days" {
  description = "Days the data bucket keeps overwritten object versions."
  type        = number
}
