output "id" {
  description = "The bucket name."
  value       = aws_s3_bucket.this.id
}

output "arn" {
  value = aws_s3_bucket.this.arn
}
