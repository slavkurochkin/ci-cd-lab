output "function_name" {
  value = aws_lambda_function.report.function_name
}

output "alerts_topic_arn" {
  description = "infra/account's budget notifications publish here."
  value       = aws_sns_topic.alerts.arn
}
