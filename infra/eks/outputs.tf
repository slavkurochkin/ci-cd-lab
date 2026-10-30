output "cluster_name" {
  description = "Feed to `aws eks update-kubeconfig --name`."
  value       = aws_eks_cluster.lab.name
}

output "cluster_endpoint" {
  description = "API server URL."
  value       = aws_eks_cluster.lab.endpoint
}

output "api_service_account" {
  description = "The ServiceAccount the API's pods must use for Pod Identity to hand them credentials. Deploy with any other name and the pods get nothing, silently."
  value       = "api"
}

output "orders_table_name" {
  description = "DynamoDB table the API reads through Pod Identity."
  value       = aws_dynamodb_table.orders.name
}

output "teardown" {
  description = "How this stack is meant to end."
  value       = "make eks-down  # deletes LoadBalancer Services first, then destroys, then sweeps"
}
