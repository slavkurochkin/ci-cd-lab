# The default case: what a consumer gets by passing only a name.
#
# mock_provider means no AWS credentials and no API calls. Every run is a plan
# against a fake provider, so these tests run offline, in seconds, in CI.

mock_provider "aws" {}

variables {
  name = "ci-cd-lab/example"
}

run "tags_are_immutable_by_default" {
  command = plan

  assert {
    condition     = aws_ecr_repository.this.image_tag_mutability == "IMMUTABLE"
    error_message = "A repository should refuse to repoint a tag unless the consumer opts out."
  }

  assert {
    condition     = aws_ecr_repository.this.image_scanning_configuration[0].scan_on_push
    error_message = "scan_on_push should default to true."
  }
}

run "lifecycle_expires_untagged_first_then_keeps_ten" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_ecr_lifecycle_policy.this.policy).rules) == 2
    error_message = "Expected exactly two lifecycle rules."
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[0].selection.tagStatus == "untagged"
    error_message = "The untagged rule must have priority 1, or untagged images count against the tagged limit."
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[1].selection.countNumber == 10
    error_message = "retained_images should default to 10."
  }
}
