# Project 8: the repositories and lifecycle policies moved into a module.
# Without these, the plan destroys both repositories -- with the images in them.

moved {
  from = aws_ecr_repository.service["api"]
  to   = module.repository["api"].aws_ecr_repository.this
}

moved {
  from = aws_ecr_lifecycle_policy.service["api"]
  to   = module.repository["api"].aws_ecr_lifecycle_policy.this
}

moved {
  from = aws_ecr_repository.service["worker"]
  to   = module.repository["worker"].aws_ecr_repository.this
}

moved {
  from = aws_ecr_lifecycle_policy.service["worker"]
  to   = module.repository["worker"].aws_ecr_lifecycle_policy.this
}
