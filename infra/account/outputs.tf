output "bucket_name" {
  description = "Globally unique, because S3 bucket names are shared across every AWS account."
  value       = module.artifacts.id
}

output "budget_name" {
  description = "Imported rather than created -- it existed in the account before Terraform knew about it."
  value       = aws_budgets_budget.monthly.name
}
