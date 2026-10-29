# Negative cases. Each run passes one bad input and expects that variable's
# validation to fail. If validation is removed or loosened, the run fails,
# because the error it expected did not happen.

mock_provider "aws" {}

run "uppercase_name_is_rejected" {
  command = plan

  variables {
    name = "CI-CD-Lab/API"
  }

  expect_failures = [var.name]
}

run "trailing_slash_is_rejected" {
  command = plan

  variables {
    name = "ci-cd-lab/"
  }

  expect_failures = [var.name]
}

run "zero_retained_images_is_rejected" {
  command = plan

  variables {
    name            = "ci-cd-lab/example"
    retained_images = 0
  }

  expect_failures = [var.retained_images]
}

run "fractional_retained_images_is_rejected" {
  command = plan

  variables {
    name            = "ci-cd-lab/example"
    retained_images = 2.5
  }

  expect_failures = [var.retained_images]
}
