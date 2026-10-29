output "bucket" {
  description = "Put this in infra/backend.hcl. Every other root reads it from there."
  value       = module.state_bucket.id
}
