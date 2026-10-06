output "name" {
  description = "Table name."
  value       = aws_dynamodb_table.this.name
}

output "arn" {
  description = "Table ARN."
  value       = aws_dynamodb_table.this.arn
}

output "stream_arn" {
  description = "Stream ARN (OLD_IMAGE), read by the release function."
  value       = aws_dynamodb_table.this.stream_arn
}

output "live_holds_index_name" {
  description = "Sparse GSI of live holds."
  value       = var.live_holds_index_name
}

output "live_holds_index_arn" {
  description = "ARN of the live-holds index (for the sweeper's Query permission)."
  value       = "${aws_dynamodb_table.this.arn}/index/${var.live_holds_index_name}"
}
