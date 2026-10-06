# Alarms, one dashboard and an SNS email topic.
#
#   api-5xx            the API returned server errors
#   <fn>-errors        a function raised (all five)
#   <fn>-throttles     Lambda refused an invocation for lack of concurrency
#   dynamodb-throttles the table or the live-holds index throttled (cap or hot partition)
#   stream-iterator-age  release is falling behind the stream
#   release-dlq        a stream batch failed for good; stock may be stuck
#
# During a load test some of these are expected to fire (throttles are the
# point of the burst test). They notify; nothing acts on them automatically.

data "aws_region" "current" {}

locals {
  region = data.aws_region.current.name
}

#trivy:ignore:AWS-0095 Alarm notifications carry no sensitive data; CloudWatch can't publish to topics encrypted with the AWS-managed SNS key, and a CMK is a production upgrade.
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
  tags = var.tags
}

# Email subscriptions stay "pending confirmation" until the link is clicked.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------------------------------------------------------------------------
# API and functions
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.name}-api-5xx"
  alarm_description   = "The API returned ${var.api_5xx_threshold}+ 5xx responses in a minute. 429s are not counted here."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = var.api_id, Stage = var.api_stage }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.api_5xx_threshold
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = var.function_names

  alarm_name          = "${each.value}-errors"
  alarm_description   = "${each.value} raised an error (a handled 409 or 429 is not an error)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each = var.function_names

  alarm_name          = "${each.value}-throttles"
  alarm_description   = "Lambda throttled ${each.value}: the account or reserved concurrency limit was reached."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# DynamoDB, stream and DLQ
# ---------------------------------------------------------------------------

# One alarm over the table's read and write throttles and the index's write
# throttles. An index that can't keep up throttles the table writes too.
resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  alarm_name          = "${var.name}-dynamodb-throttles"
  alarm_description   = "The table or the live-holds index throttled requests (on-demand cap or a hot partition)."
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "total"
    expression  = "table_reads + table_writes + index_writes"
    label       = "Throttle events"
    return_data = true
  }

  metric_query {
    id = "table_reads"
    metric {
      namespace   = "AWS/DynamoDB"
      metric_name = "ReadThrottleEvents"
      dimensions  = { TableName = var.table_name }
      stat        = "Sum"
      period      = 60
    }
  }

  metric_query {
    id = "table_writes"
    metric {
      namespace   = "AWS/DynamoDB"
      metric_name = "WriteThrottleEvents"
      dimensions  = { TableName = var.table_name }
      stat        = "Sum"
      period      = 60
    }
  }

  metric_query {
    id = "index_writes"
    metric {
      namespace   = "AWS/DynamoDB"
      metric_name = "WriteThrottleEvents"
      dimensions  = { TableName = var.table_name, GlobalSecondaryIndexName = var.live_holds_index_name }
      stat        = "Sum"
      period      = 60
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# Stock that expired via TTL comes back only as fast as release reads the
# stream. A growing iterator age means units are stuck in deleted holds.
resource "aws_cloudwatch_metric_alarm" "stream_iterator_age" {
  alarm_name          = "${var.name}-stream-iterator-age"
  alarm_description   = "release is more than ${var.iterator_age_threshold_seconds}s behind the table stream."
  namespace           = "AWS/Lambda"
  metric_name         = "IteratorAge"
  dimensions          = { FunctionName = var.function_names["release"] }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.iterator_age_threshold_seconds * 1000
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "release_dlq" {
  alarm_name          = "${var.name}-release-dlq"
  alarm_description   = "A stream batch failed after all retries. Replay it from the stream within 24h or its stock stays held."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = var.release_dlq_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Dashboard: the numbers the load tests read
# ---------------------------------------------------------------------------

locals {
  api_dims   = ["ApiId", var.api_id, "Stage", var.api_stage]
  table_dims = ["TableName", var.table_name]
  reserve    = var.function_names["reserve"]

  dashboard_widgets = [
    {
      type = "metric", x = 0, y = 0, width = 12, height = 6
      properties = {
        title  = "API requests, 4xx (incl. 429) and 5xx"
        region = local.region
        stat   = "Sum"
        period = 60
        metrics = [
          concat(["AWS/ApiGateway", "Count"], local.api_dims),
          concat(["AWS/ApiGateway", "4xx"], local.api_dims),
          concat(["AWS/ApiGateway", "5xx"], local.api_dims),
        ]
      }
    },
    {
      type = "metric", x = 12, y = 0, width = 12, height = 6
      properties = {
        title  = "API latency (ms)"
        region = local.region
        period = 60
        metrics = [
          concat(["AWS/ApiGateway", "Latency"], local.api_dims, [{ stat = "p50" }]),
          concat(["AWS/ApiGateway", "Latency"], local.api_dims, [{ stat = "p95" }]),
          concat(["AWS/ApiGateway", "IntegrationLatency"], local.api_dims, [{ stat = "p95" }]),
        ]
      }
    },
    {
      type = "metric", x = 0, y = 6, width = 8, height = 6
      properties = {
        title  = "reserve: concurrency, throttles, errors"
        region = local.region
        period = 60
        metrics = [
          ["AWS/Lambda", "ConcurrentExecutions", "FunctionName", local.reserve, { stat = "Maximum" }],
          ["AWS/Lambda", "Throttles", "FunctionName", local.reserve, { stat = "Sum" }],
          ["AWS/Lambda", "Errors", "FunctionName", local.reserve, { stat = "Sum" }],
        ]
      }
    },
    {
      type = "metric", x = 8, y = 6, width = 8, height = 6
      properties = {
        title  = "reserve duration (ms)"
        region = local.region
        period = 60
        metrics = [
          ["AWS/Lambda", "Duration", "FunctionName", local.reserve, { stat = "p50" }],
          ["AWS/Lambda", "Duration", "FunctionName", local.reserve, { stat = "p95" }],
        ]
      }
    },
    {
      type = "metric", x = 16, y = 6, width = 8, height = 6
      properties = {
        title  = "Table: consumed writes per minute"
        region = local.region
        stat   = "Sum"
        period = 60
        metrics = [
          concat(["AWS/DynamoDB", "ConsumedWriteCapacityUnits"], local.table_dims),
          concat(["AWS/DynamoDB", "ConsumedReadCapacityUnits"], local.table_dims),
        ]
      }
    },
    {
      type = "metric", x = 0, y = 12, width = 12, height = 6
      properties = {
        title  = "Table: throttles and transaction conflicts"
        region = local.region
        stat   = "Sum"
        period = 60
        metrics = [
          concat(["AWS/DynamoDB", "WriteThrottleEvents"], local.table_dims),
          concat(["AWS/DynamoDB", "ReadThrottleEvents"], local.table_dims),
          ["AWS/DynamoDB", "WriteThrottleEvents", "TableName", var.table_name, "GlobalSecondaryIndexName", var.live_holds_index_name],
          concat(["AWS/DynamoDB", "TransactionConflict"], local.table_dims),
        ]
      }
    },
    {
      type = "metric", x = 12, y = 12, width = 12, height = 6
      properties = {
        title  = "Stock return: stream lag (ms) and DLQ"
        region = local.region
        period = 60
        metrics = [
          ["AWS/Lambda", "IteratorAge", "FunctionName", var.function_names["release"], { stat = "Maximum" }],
          ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.release_dlq_name, { stat = "Maximum", yAxis = "right" }],
        ]
      }
    },
  ]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}
