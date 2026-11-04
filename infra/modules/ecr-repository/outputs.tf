output "name" {
  description = "The repository name, as passed in."
  value       = aws_ecr_repository.this.name
}

output "arn" {
  description = "For IAM policies. Scope push access to this, not to `*`."
  value       = aws_ecr_repository.this.arn
}

output "repository_url" {
  description = "The full image name without a tag: `<registry>/<name>`."
  value       = aws_ecr_repository.this.repository_url
}

output "registry_id" {
  description = "The AWS account ID that owns the registry."
  value       = aws_ecr_repository.this.registry_id
}
