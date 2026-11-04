output "url" {
  description = "The API's public URL."
  value       = aws_apigatewayv2_api.http.api_endpoint
}

output "function_name" {
  description = "The Lambda function's name."
  value       = aws_lambda_function.api.function_name
}

output "table_name" {
  description = "The DynamoDB table's name."
  value       = aws_dynamodb_table.orders.name
}

output "image_uri" {
  description = "Exactly what the function runs: repository and digest."
  value       = aws_lambda_function.api.image_uri
}
