output "api_id" {
  description = "HTTP API ID (CloudWatch ApiId dimension)."
  value       = aws_apigatewayv2_api.this.id
}

output "stage_name" {
  description = "Stage name (CloudWatch Stage dimension)."
  value       = aws_apigatewayv2_stage.default.name
}

output "url" {
  description = "Base URL of the API."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "access_log_group_name" {
  description = "Access log group."
  value       = aws_cloudwatch_log_group.access.name
}
