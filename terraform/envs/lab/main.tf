# lab environment root: wires the modules together:
#   table     -> one DynamoDB table: on-demand with a cap, stream, TTL, PITR,
#                sparse live-holds index
#   functions -> reserve, confirm, get_sale, release (stream), sweeper (schedule),
#                one IAM role each, log groups, release DLQ
#   api       -> HTTP API with stage throttling and access logs
#   alarms    -> SNS email topic, alarms, dashboard
#
# Nothing here costs money while idle except alarms and the dashboard
# (pro-rated hourly). Destroy at the end of every session:
#   TF_VAR_alarm_email=you@example.com terraform destroy

module "table" {
  source = "../../modules/table"

  name                    = local.name
  max_read_request_units  = var.table_max_read_request_units
  max_write_request_units = var.table_max_write_request_units

  tags = local.tags
}

module "functions" {
  source = "../../modules/functions"

  name       = local.name
  source_dir = "${path.root}/../../../lambdas"

  table_name            = module.table.name
  table_arn             = module.table.arn
  stream_arn            = module.table.stream_arn
  live_holds_index_name = module.table.live_holds_index_name
  live_holds_index_arn  = module.table.live_holds_index_arn

  hold_seconds   = var.hold_seconds
  hold_buckets   = var.hold_buckets
  max_qty        = var.max_qty
  sweep_schedule = var.sweep_schedule

  memory_mb                    = var.lambda_memory_mb
  reserve_reserved_concurrency = var.reserve_reserved_concurrency
  log_retention_days           = var.log_retention_days

  tags = local.tags
}

module "api" {
  source = "../../modules/api"

  name           = local.name
  invoke_arns    = module.functions.invoke_arns
  function_names = module.functions.function_names

  throttle_rate_limit  = var.api_throttle_rate_limit
  throttle_burst_limit = var.api_throttle_burst_limit
  log_retention_days   = var.log_retention_days

  tags = local.tags
}

module "alarms" {
  source = "../../modules/alarms"

  name        = local.name
  alarm_email = var.alarm_email

  api_id                = module.api.api_id
  api_stage             = module.api.stage_name
  function_names        = module.functions.function_names
  table_name            = module.table.name
  live_holds_index_name = module.table.live_holds_index_name
  release_dlq_name      = module.functions.release_dlq_name

  tags = local.tags
}
