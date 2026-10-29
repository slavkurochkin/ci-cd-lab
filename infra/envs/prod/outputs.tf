output "bucket" {
  description = "The prod data bucket's name."
  value       = module.data_bucket.id
}
