output "name" {
  description = "The generated name. Changes only when var.environment does."
  value       = random_pet.name.id
}

output "service_ports" {
  description = "Built by a `for` expression over var.service_names."
  value       = local.service_ports
}

output "manifest_path" {
  description = "The file this module wrote. `terraform destroy` removes it."
  value       = local_file.manifest.filename
}

output "token" {
  description = "Marked sensitive, so it is redacted in plan and apply output -- and stored in plain text in the state file anyway. Sensitivity is about display, not storage."
  value       = random_password.token.result
  sensitive   = true
}
