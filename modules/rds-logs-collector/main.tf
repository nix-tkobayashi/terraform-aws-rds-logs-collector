# Get current region
data "aws_region" "current" {}

# アカウントIDを取得
data "aws_caller_identity" "current" {}

# S3 bucket
resource "aws_s3_bucket" "rds_logs" {
  bucket = "${var.s3_bucket_prefix}${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
}

# S3 bucket lifecycle rule
resource "aws_s3_bucket_lifecycle_configuration" "rds_logs" {
  bucket = aws_s3_bucket.rds_logs.id

  rule {
    id     = "Delete objects after 13 months"
    status = "Enabled"

    expiration {
      days = var.log_retention_days
    }
  }
}

# IAM role for Lambda
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "rds_logs_to_s3_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# IAM policy for Lambda
resource "aws_iam_role_policy" "lambda_policy" {
  name = "rds_logs_to_s3_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "logs:CreateLogGroup"
        Resource = "arn:aws:logs:ap-northeast-1:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "arn:aws:logs:ap-northeast-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/rds_logs_to_s3:*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = "rds:DescribeDBInstances"
        Resource = "*"
      },
      {
        Sid    = "AuditFileToS3"
        Effect = "Allow"
        Action = [
          "s3:ListTagsForResource",
          "s3:PutObject",
          "s3:GetObject",
          "rds:ListTagsForResource",
          "rds:DownloadDBLogFilePortion",
          "rds:DescribeDBLogFiles"
        ]
        Resource = [
          "arn:aws:rds:ap-northeast-1:${data.aws_caller_identity.current.account_id}:db:${var.rds_prefix}-*",
          "arn:aws:s3:::${aws_s3_bucket.rds_logs.bucket}",
          "arn:aws:s3:::${aws_s3_bucket.rds_logs.bucket}/*"
        ]
      },
      {
        Sid      = "S3ListBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${aws_s3_bucket.rds_logs.bucket}"
      }
    ]
  })
}

# Lambda関数のzipファイルを src/ ディレクトリに生成
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/src/lambda_function.zip"
  source_dir  = "${path.module}/src"
}

# Lambda function
resource "aws_lambda_function" "rds_logs_to_s3" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = "rds_logs_to_s3"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.lambda_handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = 512
  timeout          = 900 # 15分

  environment {
    variables = {
      RDS_PREFIX               = "${var.rds_prefix}-"
      S3_BUCKET                = aws_s3_bucket.rds_logs.bucket
      TRANSFER_AUDIT_LOGS      = var.transfer_audit_logs
      TRANSFER_ERROR_LOGS      = var.transfer_error_logs
      TRANSFER_SLOW_QUERY_LOGS = var.transfer_slow_query_logs
    }
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.rds_logs_to_s3.function_name}"
  retention_in_days = 30
}

# EventBridge rule
resource "aws_cloudwatch_event_rule" "lambda_schedule" {
  name                = "rds-logs-to-s3-schedule"
  description         = "Triggers rds_logs_to_s3 Lambda every 10 minutes"
  schedule_expression = "rate(10 minutes)"
}

# EventBridge target
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.lambda_schedule.name
  target_id = "RdsLogsToS3Lambda"
  arn       = aws_lambda_function.rds_logs_to_s3.arn
}

# Lambda permission for EventBridge
resource "aws_lambda_permission" "eventbridge_invoke" {
  statement_id  = "EventBridgeInvokeFunction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds_logs_to_s3.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_schedule.arn
}
