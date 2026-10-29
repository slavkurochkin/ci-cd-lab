# Tests for the consuming root. A mocked provider, so no AWS calls: `apply`
# here builds fake resources in memory and throws them away.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  # The trust policy infra/ci-oidc creates: main and release tags only.
  mock_data "aws_iam_role" {
    defaults = {
      name = "ci-cd-lab-ci"
      assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect = "Allow"
          Condition = {
            StringLike = {
              "token.actions.githubusercontent.com:sub" = [
                "repo:example/ci-cd-lab:ref:refs/heads/main",
                "repo:example/ci-cd-lab:ref:refs/tags/v*",
              ]
            }
          }
        }]
      })
    }
  }
}

run "one_repository_per_service" {
  assert {
    condition     = toset(keys(output.repository_urls)) == toset(["api", "worker"])
    error_message = "Expected one repository per default service."
  }
}

run "adding_a_service_is_one_line" {
  variables {
    services = {
      api    = {}
      worker = {}
      auth   = { retained_images = 3 }
    }
  }

  assert {
    condition     = length(output.repository_urls) == 3
    error_message = "A third entry in the map should give a third repository."
  }

  assert {
    condition     = module.repository["auth"].name == "ci-cd-lab/auth"
    error_message = "The map key should become the repository name."
  }

  assert {
    condition     = length([for st in jsondecode(aws_iam_role_policy.ci_ecr_push.policy).Statement : st.Resource if st.Sid == "PushToLabRepositories"][0]) == 3
    error_message = "CI push access should cover the new repository without editing ci.tf."
  }
}

run "push_is_refused_to_a_role_any_branch_can_assume" {
  command = plan

  override_data {
    target = data.aws_iam_role.ci
    values = {
      name = "ci-cd-lab-ci"
      assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect = "Allow"
          Condition = {
            StringLike = {
              "token.actions.githubusercontent.com:sub" = "repo:example/ci-cd-lab:*"
            }
          }
        }]
      })
    }
  }

  expect_failures = [aws_iam_role_policy.ci_ecr_push]
}
