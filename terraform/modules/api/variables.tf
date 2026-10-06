variable "name" {
  description = "API name and log group prefix (\"<project>-<environment>\")."
  type        = string
}

variable "invoke_arns" {
  description = "Lambda invoke ARNs keyed by function. Must include reserve, confirm and get_sale."
  type        = map(string)
}

variable "function_names" {
  description = "Lambda function names keyed by function. Must include reserve, confirm and get_sale."
  type        = map(string)
}

variable "throttle_rate_limit" {
  description = "Stage-wide steady-state request limit per second. Requests above it get a 429 from API Gateway."
  type        = number
  default     = 500

  validation {
    condition     = var.throttle_rate_limit >= 1 && var.throttle_rate_limit <= 10000
    error_message = "throttle_rate_limit must be 1-10000 (the default account limit is 10000)."
  }
}

variable "throttle_burst_limit" {
  description = "Stage-wide burst (token bucket size). Requests above it get a 429 from API Gateway."
  type        = number
  default     = 1000

  validation {
    condition     = var.throttle_burst_limit >= 1 && var.throttle_burst_limit <= 5000
    error_message = "throttle_burst_limit must be 1-5000 (the default account limit is 5000)."
  }
}

variable "log_retention_days" {
  description = "Retention for the access log group."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
