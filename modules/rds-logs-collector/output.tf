output "lambda_function_name" {
  description = "Lambda関数の名前"
  value       = aws_lambda_function.rds_logs_to_s3.function_name
}

output "s3_bucket_name" {
  description = "作成されたS3バケットの名前"
  value       = aws_s3_bucket.rds_logs.bucket
}

output "lambda_role_arn" {
  description = "Lambda実行ロールのARN"
  value       = aws_iam_role.lambda_role.arn
}
