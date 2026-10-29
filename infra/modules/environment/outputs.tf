output "bucket" {
  description = "The data bucket's name."
  value       = module.data_bucket.id
}

output "api_url" {
  description = "The api's public URL."
  value       = module.api.url
}

output "api_image" {
  description = "Exactly what the function runs."
  value       = module.api.image_uri
}
