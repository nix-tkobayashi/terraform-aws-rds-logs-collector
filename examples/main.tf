module "rds_logs_collector" {
  source = "../modules/rds-logs-collector"

  s3_bucket_prefix         = local.s3_bucket_prefix
  rds_prefix               = local.rds_prefix
  transfer_audit_logs      = local.transfer_audit_logs
  transfer_error_logs      = local.transfer_error_logs
  transfer_slow_query_logs = local.transfer_slow_query_logs
  log_retention_days       = local.log_retention_days
}