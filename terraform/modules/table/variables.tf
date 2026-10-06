variable "name" {
  description = "Table name."
  type        = string
}

variable "live_holds_index_name" {
  description = "Name of the sparse GSI of live (HELD) holds that the sweeper reads."
  type        = string
  default     = "live-holds"
}

variable "max_read_request_units" {
  description = "On-demand read cap (read request units per second) for the table and its index. Requests above it are throttled, not billed."
  type        = number
  default     = 4000

  validation {
    condition     = var.max_read_request_units >= 1
    error_message = "max_read_request_units must be at least 1."
  }
}

variable "max_write_request_units" {
  description = "On-demand write cap (write request units per second) for the table and its index. A reserve costs about 7: three transactional item writes at 2 each, plus the index write."
  type        = number
  default     = 4000

  validation {
    condition     = var.max_write_request_units >= 1
    error_message = "max_write_request_units must be at least 1."
  }
}

variable "tags" {
  description = "Tags applied to the table."
  type        = map(string)
  default     = {}
}
