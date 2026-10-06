variable "name" {
  description = "Name prefix for every resource (\"<project>-<environment>\")."
  type        = string
}

variable "source_dir" {
  description = "Path to the lambdas/ folder: one sub-folder per function plus shared/."
  type        = string
}

# --- Table -------------------------------------------------------------------

variable "table_name" {
  description = "DynamoDB table name."
  type        = string
}

variable "table_arn" {
  description = "DynamoDB table ARN."
  type        = string
}

variable "stream_arn" {
  description = "DynamoDB stream ARN, consumed by the release function."
  type        = string
}

variable "live_holds_index_name" {
  description = "Sparse GSI of live holds."
  type        = string
}

variable "live_holds_index_arn" {
  description = "ARN of the live-holds index."
  type        = string
}

# --- Behaviour ---------------------------------------------------------------

variable "hold_seconds" {
  description = "How long a hold lasts before it can no longer be confirmed."
  type        = number
  default     = 600

  validation {
    condition     = var.hold_seconds >= 30
    error_message = "hold_seconds must be at least 30."
  }
}

variable "hold_buckets" {
  description = "Number of held_bucket values that spread live holds over the sparse index."
  type        = number
  default     = 10

  validation {
    condition     = var.hold_buckets >= 1 && var.hold_buckets <= 100
    error_message = "hold_buckets must be between 1 and 100."
  }
}

variable "max_qty" {
  description = "Most units one reservation may hold."
  type        = number
  default     = 4

  validation {
    condition     = var.max_qty >= 1
    error_message = "max_qty must be at least 1."
  }
}

variable "sweep_schedule" {
  description = "EventBridge schedule expression for the sweeper."
  type        = string
  default     = "rate(1 minute)"
}

# --- Capacity ----------------------------------------------------------------

variable "memory_mb" {
  description = "Memory for every function, in MB. CPU scales with it."
  type        = number
  default     = 256
}

variable "reserve_reserved_concurrency" {
  description = "Reserved concurrency for the reserve function. Null leaves it unreserved: Lambda rejects a reservation that leaves fewer than 100 unreserved, and new accounts can have a total quota as low as 10."
  type        = number
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the function log groups."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
