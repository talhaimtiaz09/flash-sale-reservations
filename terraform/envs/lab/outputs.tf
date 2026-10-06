output "api_url" {
  description = "Base URL of the API (loadtest: BASE_URL)."
  value       = module.api.url
}

output "table_name" {
  description = "DynamoDB table name (scripts/seed_sale.py --table)."
  value       = module.table.name
}

output "function_names" {
  description = "Lambda function names."
  value       = module.functions.function_names
}

output "release_dlq_url" {
  description = "Queue that receives stream batches the release function gave up on."
  value       = module.functions.release_dlq_url
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${module.alarms.dashboard_name}"
}

output "alerts_topic_arn" {
  description = "SNS topic for alarms. Confirm the email subscription after the first apply."
  value       = module.alarms.alerts_topic_arn
}

output "region" {
  description = "AWS region."
  value       = var.region
}
