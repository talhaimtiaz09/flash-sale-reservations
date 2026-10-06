# The five Lambda functions, Python 3.13 on arm64, boto3 only (no layers).
#
#   reserve, confirm, get_sale  behind the HTTP API (modules/api)
#   release                     DynamoDB Streams consumer: returns stock on TTL deletes
#   sweeper                     EventBridge schedule: deletes expired holds, returns stock
#
# Each zip holds <name>.py plus lambdas/shared/. One IAM role per function,
# and each role only reaches the pk prefixes that function touches
# (dynamodb:LeadingKeys), so reserve can't delete holds and confirm can't
# touch stock.

locals {
  functions = {
    reserve  = { timeout = 5, description = "POST /sales/{sale_id}/reserve: hold units for a buyer." }
    confirm  = { timeout = 5, description = "POST /holds/{hold_id}/confirm: turn a live hold into an order." }
    get_sale = { timeout = 5, description = "GET /sales/{sale_id}: remaining stock and status." }
    release  = { timeout = 30, description = "Streams consumer: return stock when TTL deletes an unconfirmed hold." }
    sweeper  = { timeout = 60, description = "Schedule: delete expired holds and return their stock." }
  }

  function_names = { for k in keys(local.functions) : k => "${var.name}-${replace(k, "_", "-")}" }

  environment = {
    TABLE_NAME       = var.table_name
    LIVE_HOLDS_INDEX = var.live_holds_index_name
    HOLD_SECONDS     = tostring(var.hold_seconds)
    HOLD_BUCKETS     = tostring(var.hold_buckets)
    MAX_QTY          = tostring(var.max_qty)
  }

  # What each function may do to which items. The prefixes are the table's
  # pk prefixes (lambdas/shared/db.py). A transaction is authorised item by
  # item, so these apply inside TransactWriteItems too.
  table_access = {
    reserve = [
      { sid = "ReadSaleKeyAndHold", actions = ["dynamodb:GetItem"], prefixes = ["SALE#*", "IDEM#*", "HOLD#*"] },
      { sid = "TakeStock", actions = ["dynamodb:UpdateItem"], prefixes = ["SALE#*"] },
      { sid = "WriteHoldAndKey", actions = ["dynamodb:PutItem"], prefixes = ["HOLD#*", "IDEM#*"] },
    ]
    confirm = [
      # GetItem covers the old item returned when the confirm condition fails.
      { sid = "ConfirmHold", actions = ["dynamodb:UpdateItem", "dynamodb:GetItem"], prefixes = ["HOLD#*"] },
    ]
    get_sale = [
      { sid = "ReadSale", actions = ["dynamodb:Query"], prefixes = ["SALE#*"] },
    ]
    release = [
      { sid = "ReturnStock", actions = ["dynamodb:UpdateItem"], prefixes = ["SALE#*"] },
      { sid = "WriteReturnMarker", actions = ["dynamodb:PutItem"], prefixes = ["RETURN#*"] },
    ]
    sweeper = [
      { sid = "DeleteExpiredHold", actions = ["dynamodb:DeleteItem"], prefixes = ["HOLD#*"] },
      { sid = "ReturnStock", actions = ["dynamodb:UpdateItem"], prefixes = ["SALE#*"] },
      { sid = "WriteReturnMarker", actions = ["dynamodb:PutItem"], prefixes = ["RETURN#*"] },
    ]
  }
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

data "archive_file" "fn" {
  for_each = local.functions

  type        = "zip"
  output_path = "${path.root}/.build/${each.key}.zip"

  source {
    filename = "${each.key}.py"
    content  = file("${var.source_dir}/${each.key}/${each.key}.py")
  }

  dynamic "source" {
    for_each = fileset("${var.source_dir}/shared", "*.py")
    content {
      filename = "shared/${source.value}"
      content  = file("${var.source_dir}/shared/${source.value}")
    }
  }
}

# ---------------------------------------------------------------------------
# IAM: one role per function
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fn" {
  for_each = local.functions

  name               = local.function_names[each.key]
  description        = "Lambda ${local.function_names[each.key]}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = var.tags
}

data "aws_iam_policy_document" "fn" {
  for_each = local.functions

  dynamic "statement" {
    for_each = local.table_access[each.key]
    content {
      sid       = statement.value.sid
      effect    = "Allow"
      actions   = statement.value.actions
      resources = [var.table_arn]

      condition {
        test     = "ForAllValues:StringLike"
        variable = "dynamodb:LeadingKeys"
        values   = statement.value.prefixes
      }
    }
  }

  # The log group is created below, so the function only needs to write to it.
  statement {
    sid       = "OwnLogGroup"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.fn[each.key].arn}:*"]
  }
}

resource "aws_iam_role_policy" "fn" {
  for_each = local.functions

  name   = "table-and-logs"
  role   = aws_iam_role.fn[each.key].id
  policy = data.aws_iam_policy_document.fn[each.key].json
}

# release: read the table's stream, and send failed batches to its DLQ.
# dynamodb:ListStreams has no resource-level permissions; everything else is
# on the one stream and queue ARN.
data "aws_iam_policy_document" "release_stream" {
  statement {
    sid       = "ReadStream"
    effect    = "Allow"
    actions   = ["dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator"]
    resources = [var.stream_arn]
  }

  statement {
    sid       = "ListStreams"
    effect    = "Allow"
    actions   = ["dynamodb:ListStreams"]
    resources = ["*"]
  }

  statement {
    sid       = "FailedBatchesToDlq"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.release_dlq.arn]
  }
}

resource "aws_iam_role_policy" "release_stream" {
  name   = "stream-and-dlq"
  role   = aws_iam_role.fn["release"].id
  policy = data.aws_iam_policy_document.release_stream.json
}

# sweeper: query the sparse live-holds index.
data "aws_iam_policy_document" "sweeper_index" {
  statement {
    sid       = "QueryLiveHolds"
    effect    = "Allow"
    actions   = ["dynamodb:Query"]
    resources = [var.live_holds_index_arn]
  }
}

resource "aws_iam_role_policy" "sweeper_index" {
  name   = "live-holds-index"
  role   = aws_iam_role.fn["sweeper"].id
  policy = data.aws_iam_policy_document.sweeper_index.json
}

# ---------------------------------------------------------------------------
# Functions and log groups
# ---------------------------------------------------------------------------

#trivy:ignore:AWS-0017 Lambda logs carry no secrets; a CMK per log group is a production upgrade.
resource "aws_cloudwatch_log_group" "fn" {
  for_each = local.functions

  name              = "/aws/lambda/${local.function_names[each.key]}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

#trivy:ignore:AWS-0066 X-Ray is billed per trace and the oversell test alone sends 10,000 requests; CloudWatch metrics and access logs cover the tests.
resource "aws_lambda_function" "fn" {
  for_each = local.functions

  function_name = local.function_names[each.key]
  description   = each.value.description
  role          = aws_iam_role.fn[each.key].arn

  runtime       = "python3.13"
  architectures = ["arm64"]
  handler       = "${each.key}.handler"
  memory_size   = var.memory_mb
  timeout       = each.value.timeout

  filename         = data.archive_file.fn[each.key].output_path
  source_code_hash = data.archive_file.fn[each.key].output_base64sha256

  # Null (the default) leaves reserve unreserved. New accounts can have a
  # concurrency quota as low as 10, and Lambda refuses any reservation that
  # leaves fewer than 100 unreserved, so a fixed number here would fail the
  # first apply on such an account. Set it once the quota allows.
  reserved_concurrent_executions = each.key == "reserve" ? var.reserve_reserved_concurrency : null

  environment {
    variables = local.environment
  }

  logging_config {
    log_format            = "JSON"
    log_group             = aws_cloudwatch_log_group.fn[each.key].name
    application_log_level = "INFO"
    system_log_level      = "INFO" # keeps platform.report lines: init duration = cold starts
  }

  tracing_config {
    mode = "PassThrough"
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy.fn]
}

# ---------------------------------------------------------------------------
# release: stream -> function, failures -> DLQ
# ---------------------------------------------------------------------------

# SQS-managed SSE. The messages are stream positions, not item data.
resource "aws_sqs_queue" "release_dlq" {
  name                      = "${var.name}-release-dlq"
  message_retention_seconds = 14 * 24 * 3600
  sqs_managed_sse_enabled   = true

  tags = var.tags
}

resource "aws_lambda_event_source_mapping" "release" {
  event_source_arn = var.stream_arn
  function_name    = aws_lambda_function.fn["release"].arn

  # Table and mapping are created in the same apply; TRIM_HORIZON means no
  # record written in between is skipped.
  starting_position                  = "TRIM_HORIZON"
  batch_size                         = 100
  maximum_batching_window_in_seconds = 5

  # A bad record splits the batch until it is alone, retries are capped, and
  # what still fails goes to the DLQ instead of blocking the shard. The DLQ
  # gets the shard and sequence range, not the records; replay from the
  # stream within its 24h retention. Every return is idempotent, so replays
  # and retries are safe.
  function_response_types        = ["ReportBatchItemFailures"]
  bisect_batch_on_function_error = true
  maximum_retry_attempts         = 5
  maximum_record_age_in_seconds  = 3600

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.release_dlq.arn
    }
  }

  # Only TTL deletes of HELD holds invoke the function. Every stock update
  # also lands on the stream; without this filter each one would be an
  # invocation that does nothing.
  filter_criteria {
    filter {
      pattern = jsonencode({
        eventName    = ["REMOVE"]
        userIdentity = { type = ["Service"], principalId = ["dynamodb.amazonaws.com"] }
        dynamodb     = { OldImage = { status = { S = ["HELD"] } } }
      })
    }
  }

  depends_on = [aws_iam_role_policy.release_stream]
}

# ---------------------------------------------------------------------------
# sweeper: EventBridge schedule
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "sweeper" {
  name                = "${var.name}-sweeper"
  description         = "Runs the sweeper: expired holds back to stock without waiting for TTL."
  schedule_expression = var.sweep_schedule

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "sweeper" {
  rule = aws_cloudwatch_event_rule.sweeper.name
  arn  = aws_lambda_function.fn["sweeper"].arn
}

resource "aws_lambda_permission" "sweeper_schedule" {
  statement_id  = "AllowEventBridgeSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["sweeper"].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sweeper.arn
}
