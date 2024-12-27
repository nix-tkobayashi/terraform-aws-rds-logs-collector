locals {
  s3_bucket_prefix         = "rds-logs-collector-"
  rds_prefix               = "example-rds-"
  transfer_audit_logs      = "true"
  transfer_error_logs      = "false"
  transfer_slow_query_logs = "false"
  log_retention_days       = "395"
}
