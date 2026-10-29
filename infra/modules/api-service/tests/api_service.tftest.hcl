# Offline tests: mocked provider, no AWS.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "us-east-1"
    }
  }
}

variables {
  name_prefix              = "ci-cd-lab-test"
  environment              = "test"
  image_digest             = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
  permissions_boundary_arn = "arn:aws:iam::123456789012:policy/ci-cd-lab-lambda-boundary"
}

run "runs_the_image_by_digest" {
  command = plan

  assert {
    condition     = aws_lambda_function.api.image_uri == "123456789012.dkr.ecr.us-east-1.amazonaws.com/ci-cd-lab/api@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    error_message = "image_uri should be <repository>@<digest>."
  }
}

run "the_role_carries_the_boundary" {
  command = plan

  assert {
    condition     = aws_iam_role.lambda.permissions_boundary == var.permissions_boundary_arn
    error_message = "Without the boundary, the CI apply role is not allowed to create this role."
  }
}

run "cost_guards_are_on" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.api.retention_in_days == 7
    error_message = "Logs need a retention period, or they are kept and billed forever."
  }

  assert {
    condition     = aws_apigatewayv2_stage.default.default_route_settings[0].throttling_rate_limit == 5
    error_message = "The API needs a throttle: it is a public URL."
  }

  assert {
    condition     = aws_dynamodb_table.orders.billing_mode == "PAY_PER_REQUEST"
    error_message = "Provisioned capacity bills while idle."
  }
}

run "the_function_finds_its_table" {
  command = plan

  assert {
    condition     = aws_lambda_function.api.environment[0].variables["ORDERS_TABLE"] == "ci-cd-lab-test-orders"
    error_message = "ORDERS_TABLE must name this environment's table."
  }
}

run "a_tag_is_not_a_digest" {
  command = plan

  variables {
    image_digest = "0.2.0"
  }

  expect_failures = [var.image_digest]
}

run "names_outside_the_apply_roles_pattern_are_rejected" {
  command = plan

  variables {
    name_prefix = "my-service-dev"
  }

  expect_failures = [var.name_prefix]
}
