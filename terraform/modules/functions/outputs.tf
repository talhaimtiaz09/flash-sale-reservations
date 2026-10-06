output "function_names" {
  description = "Function names, keyed by function (reserve, confirm, get_sale, release, sweeper)."
  value       = { for k, f in aws_lambda_function.fn : k => f.function_name }
}

output "invoke_arns" {
  description = "Invoke ARNs for API Gateway integrations, keyed by function."
  value       = { for k, f in aws_lambda_function.fn : k => f.invoke_arn }
}

output "log_group_names" {
  description = "Function log group names, keyed by function."
  value       = { for k, g in aws_cloudwatch_log_group.fn : k => g.name }
}

output "release_dlq_name" {
  description = "Queue that receives stream batches the release function could not process."
  value       = aws_sqs_queue.release_dlq.name
}

output "release_dlq_url" {
  description = "URL of the release DLQ."
  value       = aws_sqs_queue.release_dlq.url
}
