output "id" {
  description = "The bucket name."
  value       = aws_s3_bucket.this.id
}

output "arn" {
  description = "For IAM policies and bucket policies."
  value       = aws_s3_bucket.this.arn
}
