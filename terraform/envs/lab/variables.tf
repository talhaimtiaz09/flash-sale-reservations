variable "region" {
  description = "AWS region for all resources. Keep in sync with the backend region in backend.tf."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name. Used for naming and tagging."
  type        = string
  default     = "flash-sale-reservations"
}

variable "environment" {
  description = "Environment name. The bootstrap apply role is scoped to names starting with \"<project>-<environment>-\"."
  type        = string
  default     = "lab"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
  default     = "talhaimtiaz09"
}

variable "alarm_email" {
  description = "Email address for alarm notifications. CI sets it from the ALARM_EMAIL repository variable (TF_VAR_alarm_email)."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alarm_email))
    error_message = "alarm_email must be an email address."
  }
}

# --- Sale behaviour ------------------------------------------------------------

variable "hold_seconds" {
  description = "How long a hold lasts. The ttl-return test sets it to 60 so the run doesn't take ten minutes."
  type        = number
  default     = 600
}

variable "hold_buckets" {
  description = "held_bucket values spreading live holds over the sparse index."
  type        = number
  default     = 10
}

variable "max_qty" {
  description = "Most units one reservation may hold."
  type        = number
  default     = 4
}

variable "sweep_schedule" {
  description = "EventBridge schedule expression for the sweeper."
  type        = string
  default     = "rate(1 minute)"
}

# --- Limits: where a burst gets told no --------------------------------------

variable "api_throttle_rate_limit" {
  description = "API stage steady-state limit, requests per second. Above it, API Gateway answers 429."
  type        = number
  default     = 500
}

variable "api_throttle_burst_limit" {
  description = "API stage burst limit. Above it, API Gateway answers 429."
  type        = number
  default     = 1000
}

variable "reserve_reserved_concurrency" {
  description = "Reserved concurrency for reserve. Null by default: Lambda rejects any reservation that leaves fewer than 100 unreserved, and a new account's quota can be 10. See the README."
  type        = number
  default     = null
}

variable "table_max_read_request_units" {
  description = "On-demand read cap per second (table and index). A runaway test is throttled, not billed."
  type        = number
  default     = 4000
}

variable "table_max_write_request_units" {
  description = "On-demand write cap per second (table and index). A runaway test is throttled, not billed."
  type        = number
  default     = 4000
}

variable "lambda_memory_mb" {
  description = "Memory for every function, in MB."
  type        = number
  default     = 256
}

variable "log_retention_days" {
  description = "Retention for function and access log groups."
  type        = number
  default     = 14
}
