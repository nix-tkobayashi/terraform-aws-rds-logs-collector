variable "s3_bucket_prefix" {
  description = "ログを保存するS3バケットのプレフィックス"
  type        = string
}

variable "rds_prefix" {
  description = "RDSログのS3プレフィックス"
  type        = string
}

variable "transfer_audit_logs" {
  description = "監査ログを転送するかどうか"
  type        = bool
  default     = true
}

variable "transfer_error_logs" {
  description = "エラーログを転送するかどうか"
  type        = bool
  default     = false
}

variable "transfer_slow_query_logs" {
  description = "スロークエリログを転送するかどうか"
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "ログの保持日数"
  type        = number
  default     = 395
}
