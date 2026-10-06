variable "name" {
  description = "Name prefix for alarms, the topic and the dashboard (\"<project>-<environment>\")."
  type        = string
}

variable "alarm_email" {
  description = "Email address subscribed to the alerts topic."
  type        = string
}

variable "api_id" {
  description = "HTTP API ID."
  type        = string
}

variable "api_stage" {
  description = "HTTP API stage name."
  type        = string
}

variable "function_names" {
  description = "Function names keyed by function. Must include reserve and release."
  type        = map(string)
}

variable "table_name" {
  description = "DynamoDB table name."
  type        = string
}

variable "live_holds_index_name" {
  description = "Sparse GSI of live holds."
  type        = string
}

variable "release_dlq_name" {
  description = "Name of the release function's failure queue."
  type        = string
}

variable "api_5xx_threshold" {
  description = "API 5xx responses per minute that raise the alarm."
  type        = number
  default     = 5
}

variable "iterator_age_threshold_seconds" {
  description = "How far behind the stream release may fall, in seconds, before the alarm fires."
  type        = number
  default     = 60
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
