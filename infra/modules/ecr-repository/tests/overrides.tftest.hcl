# A consumer that changes every default. Each input must reach the resource it
# is meant to control, and nothing else.

mock_provider "aws" {}

variables {
  name                 = "team/service.name-v2"
  retained_images      = 3
  untagged_expiry_days = 7
  immutable_tags       = false
  scan_on_push         = false
  tags                 = { Owner = "platform" }
}

run "every_input_reaches_its_resource" {
  command = plan

  assert {
    condition     = aws_ecr_repository.this.name == "team/service.name-v2"
    error_message = "A namespaced name with . and - should pass validation unchanged."
  }

  assert {
    condition     = aws_ecr_repository.this.image_tag_mutability == "MUTABLE"
    error_message = "immutable_tags = false should give MUTABLE."
  }

  assert {
    condition     = !aws_ecr_repository.this.image_scanning_configuration[0].scan_on_push
    error_message = "scan_on_push = false was ignored."
  }

  assert {
    condition     = aws_ecr_repository.this.tags["Owner"] == "platform"
    error_message = "tags were not passed to the repository."
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[0].selection.countNumber == 7
    error_message = "untagged_expiry_days did not reach the untagged rule."
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[1].selection.countNumber == 3
    error_message = "retained_images did not reach the tagged rule."
  }
}
