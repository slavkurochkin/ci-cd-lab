variable "environment" {
  description = "This environment's name. Must match the directory and the backend key."
  type        = string
}

variable "enabled" {
  description = "false destroys everything in this environment on the next apply."
  type        = bool
  default     = true
}

variable "api_image_digest" {
  description = "Platform manifest digest of the api image, from a release. Deploying is changing this line."
  type        = string
}

variable "data_noncurrent_days" {
  description = "Days the data bucket keeps overwritten object versions."
  type        = number
}
