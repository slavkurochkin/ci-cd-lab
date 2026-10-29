output "role_arn" {
  description = "Set as `role-to-assume` in a workflow. This is an ARN, not a credential -- it is safe in plain sight in a workflow file, which is the entire point of OIDC."
  value       = aws_iam_role.ci.arn
}

output "role_name" {
  description = "infra/eks looks the role up by this name to attach cluster permissions to it."
  value       = aws_iam_role.ci.name
}

output "oidc_provider_arn" {
  description = "The account's GitHub OIDC provider. Any other stack needing it should look it up, never create a second one."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "tf_plan_role_arn" {
  description = "Project 9. Set as the AWS_TF_PLAN_ROLE_ARN repository variable."
  value       = aws_iam_role.tf_plan.arn
}

output "tf_apply_role_arns" {
  description = "Project 9. One per environment: AWS_TF_APPLY_DEV_ROLE_ARN and AWS_TF_APPLY_PROD_ROLE_ARN."
  value       = { for env, r in aws_iam_role.tf_apply : env => r.arn }
}
