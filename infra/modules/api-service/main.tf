# The api service on Lambda: one image, one table, one public HTTP endpoint.
# Capstone B. README.md explains the choices that are not obvious.

data "aws_ecr_repository" "api" {
  name = var.repository_name
}

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "orders" {
  #checkov:skip=CKV_AWS_28:No point-in-time recovery. It bills per GB per month, and an environment is meant to be deleted and recreated.
  #checkov:skip=CKV_AWS_119:AWS-owned key, not a customer KMS key. A KMS key is $1/month per environment, for orders that are test data.
  name         = "${var.name_prefix}-orders"
  billing_mode = "PAY_PER_REQUEST" # nothing billed while idle
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }

  # Off, because Capstone B's second deliverable is a PR that deletes the
  # whole environment. Deleting prod data is stopped by policy instead.
  deletion_protection_enabled = false
}

# ---------------------------------------------------------------------------
# The function
# ---------------------------------------------------------------------------

# Created before the function. Otherwise Lambda creates it on first invoke,
# with no retention and outside Terraform, and `destroy` leaves it behind.
resource "aws_cloudwatch_log_group" "api" {
  #checkov:skip=CKV_AWS_158:No KMS key on logs, for the same $1/month reason as the table.
  #checkov:skip=CKV_AWS_338:Seven days, not a year. These are lab logs; retention is what bounds their cost.
  name              = "/aws/lambda/${var.name_prefix}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "lambda" {
  name        = "${var.name_prefix}-api-lambda"
  description = "Execution role for ${var.name_prefix}-api. Bounded: it can never exceed the permissions boundary."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  # The apply role that creates this role may only do so with this boundary
  # attached (infra/ci-oidc). Remove this line and the apply fails with
  # AccessDenied, which is the point.
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy" "lambda" {
  name = "logs-and-orders"
  role = aws_iam_role.lambda.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${aws_cloudwatch_log_group.api.arn}:*"]
      },
      {
        Sid      = "ReadWriteOwnTable"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
        Resource = [aws_dynamodb_table.orders.arn]
      },
    ]
  })
}

resource "aws_lambda_function" "api" {
  #checkov:skip=CKV_AWS_115:No reserved concurrency. A new account's limit can be 10, and AWS refuses any reservation that leaves fewer than 10 unreserved. The API Gateway throttle is the cost guard instead.
  #checkov:skip=CKV_AWS_116:No dead-letter queue. Invocations are synchronous HTTP; the caller gets the error.
  #checkov:skip=CKV_AWS_117:Not in a VPC. It needs no private network, and a VPC Lambda needs a NAT Gateway to reach anything, which this curriculum never creates.
  #checkov:skip=CKV_AWS_173:Environment variables hold a table name and an environment name, nothing secret.
  #checkov:skip=CKV_AWS_272:No code signing. Images are signed and attested at build time (Project 5) and deployed by digest.
  #checkov:skip=CKV_AWS_50:No X-Ray tracing. Project 16 is where tracing is added.
  function_name = "${var.name_prefix}-api"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  architectures = ["x86_64"] # the pipeline builds linux/amd64 only

  # By digest, never by tag. The plan shows exactly which image will run, and
  # changing it is a one-line diff in terraform.tfvars that gets reviewed.
  image_uri = "${data.aws_ecr_repository.api.repository_url}@${var.image_digest}"

  memory_size = var.memory_size
  timeout     = var.timeout

  environment {
    variables = {
      ENVIRONMENT  = var.environment
      ORDERS_TABLE = aws_dynamodb_table.orders.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.api, aws_iam_role_policy.lambda]
}

# ---------------------------------------------------------------------------
# The HTTP endpoint
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "http" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  #checkov:skip=CKV_AWS_309:Public on purpose: a demo API with no user data. The stage throttle bounds what an anonymous caller can cost.
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  #checkov:skip=CKV_AWS_76:No access logging. Function logs already record every request that gets through the throttle.
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true

  # The cost guard. A public URL can be called by anyone, as often as they
  # like; past this rate API Gateway answers 429 and Lambda never runs.
  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }
}

resource "aws_lambda_permission" "apigateway" {
  statement_id  = "AllowInvokeFromHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}
