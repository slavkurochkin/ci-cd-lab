output "registry" {
  description = "The account's ECR registry host. Feed to docker login and to the image name."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "repository_urls" {
  description = "Full image names, by service."
  value       = { for k, r in module.repository : k => r.repository_url }
}

output "retained_images" {
  description = "How many tagged images survive per repository. Beyond this, the oldest expire."
  value       = var.retained_images
}
