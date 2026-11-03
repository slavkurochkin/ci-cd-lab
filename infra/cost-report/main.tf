# The weekly cost digest and the budget alerts, posted to Slack. Project 18.
#
#   EventBridge Scheduler (Mondays 08:00 UTC) ──▶ Lambda ──▶ Slack webhook
#   AWS Budgets ──▶ SNS ──────────────────────────▲
#   Pipeline health workflow ──▶ S3 runner-minutes.json ──▶ (read by the Lambda)
#
# Idle cost: $0. Scheduler, Lambda, SNS and the log group sit inside the free
# tier at this volume. Each digest makes two Cost Explorer requests, $0.02.
#
# The webhook URL is an SSM SecureString created by hand
# (/ci-cd-lab/slack/cost-webhook) and read at run time. It is never a
# Terraform value: a value in Terraform is a value in the state file.

data "aws_caller_identity" "current" {}

locals {
  name           = "ci-cd-lab-cost-report"
  account_id     = data.aws_caller_identity.current.account_id
  bucket         = "ci-cd-lab-artifacts-${local.account_id}"
  runner_key     = "pipeline/runner-minutes.json"
  webhook_param  = "/ci-cd-lab/slack/cost-webhook"
  alerts_topic   = "ci-cd-lab-budget-alerts"
  log_group_name = "/aws/lambda/${local.name}"
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/cost_report.py"
  output_path = "${path.module}/.build/cost_report.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = local.log_group_name
  retention_in_days = 14
}

resource "aws_lambda_function" "report" {
  function_name    = local.name
  description      = "Weekly cost digest and budget alerts to Slack (Project 18)"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "cost_report.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      WEBHOOK_PARAMETER = local.webhook_param
      RUNNER_BUCKET     = local.bucket
      RUNNER_KEY        = local.runner_key
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

resource "aws_iam_role" "lambda" {
  name = local.name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "cost-report"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
      {
        # Cost Explorer has no resource-level permissions: "*" is the only form.
        Sid      = "CostExplorer"
        Effect   = "Allow"
        Action   = ["ce:GetCostAndUsage"]
        Resource = "*"
      },
      {
        # SecureString with the AWS managed key aws/ssm, whose key policy
        # already allows decryption through SSM for this account's principals.
        Sid      = "Webhook"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:us-east-1:${local.account_id}:parameter${local.webhook_param}"
      },
      {
        Sid      = "RunnerMinutes"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${local.bucket}/${local.runner_key}"
      },
      {
        # Without ListBucket a missing object is AccessDenied, not NoSuchKey,
        # and the digest could not tell "never written" from "not allowed".
        Sid       = "RunnerMinutesExists"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = "arn:aws:s3:::${local.bucket}"
        Condition = { StringEquals = { "s3:prefix" = local.runner_key } }
      },
    ]
  })
}

# --- the weekly digest ---------------------------------------------------------------------

resource "aws_scheduler_schedule" "weekly" {
  name                         = "${local.name}-weekly"
  description                  = "Monday 08:00 UTC cost digest (Project 18)"
  schedule_expression          = "cron(0 8 ? * MON *)"
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.report.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ source = "schedule" })

    retry_policy {
      maximum_retry_attempts = 1
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name = "${local.name}-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "invoke"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.report.arn
    }]
  })
}

# --- budget alerts -------------------------------------------------------------------------

# infra/account's budget publishes here by ARN. The topic policy is what
# lets AWS Budgets publish at all; without it the notification is dropped
# with no error anywhere you would look.
resource "aws_sns_topic" "alerts" {
  name = local.alerts_topic
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "Budgets"
      Effect    = "Allow"
      Principal = { Service = "budgets.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.alerts.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:budgets::${local.account_id}:*" }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "alerts" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.report.arn
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "sns-budget-alerts"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.report.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

# --- the runner-minutes handoff ------------------------------------------------------------

# The Pipeline health workflow assumes the existing CI role (infra/ci-oidc)
# and writes one object. Attached here by role name, the same way infra/eks
# attaches its cluster policy, so ci-oidc does not need to know this exists.
resource "aws_iam_role_policy" "ci_runner_minutes" {
  name = "write-runner-minutes"
  role = "ci-cd-lab-ci"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "arn:aws:s3:::${local.bucket}/${local.runner_key}"
    }]
  })
}
