output "bucket" {
  description = "The data bucket's name."
  value       = one(module.env[*].bucket)
}

output "api_url" {
  description = "The api's public URL."
  value       = one(module.env[*].api_url)
}

output "api_image" {
  description = "Exactly what the function runs."
  value       = one(module.env[*].api_image)
}
