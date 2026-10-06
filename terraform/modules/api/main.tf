# HTTP API in front of reserve, confirm and get_sale.
#
# - Stage throttling (rate and burst) is the first line of "failing politely":
#   past it, API Gateway answers 429 itself and nothing behind it runs. Keep
#   it below what the functions and the table cap can serve, so the client
#   sees API Gateway's 429 before anything downstream throttles.
# - Access logs as JSON, one line per request, for the load-test write-ups.
# - No authorizer: the API is public on purpose for the lab (see README).

locals {
  routes = {
    "POST /sales/{sale_id}/reserve" = "reserve"
    "POST /holds/{hold_id}/confirm" = "confirm"
    "GET /sales/{sale_id}"          = "get_sale"
  }

  integrated_functions = toset(values(local.routes))
}

resource "aws_apigatewayv2_api" "this" {
  name          = var.name
  description   = "Flash-sale reservations: reserve, confirm, read stock."
  protocol_type = "HTTP"

  tags = var.tags
}

resource "aws_apigatewayv2_integration" "fn" {
  for_each = local.integrated_functions

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.invoke_arns[each.key]
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

resource "aws_apigatewayv2_route" "this" {
  for_each = local.routes

  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.fn[each.value].id}"
}

# Each function can be invoked by its own route only.
resource "aws_lambda_permission" "route" {
  for_each = local.routes

  statement_id  = "AllowApiRoute-${each.value}"
  action        = "lambda:InvokeFunction"
  function_name = var.function_names[each.value]
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/${replace(each.key, " ", "")}"
}

#trivy:ignore:AWS-0017 Access logs carry no secrets; a CMK per log group is a production upgrade.
resource "aws_cloudwatch_log_group" "access" {
  name              = "/${var.name}/api-access"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      requestTime        = "$context.requestTimeEpoch"
      ip                 = "$context.identity.sourceIp"
      routeKey           = "$context.routeKey"
      status             = "$context.status"
      responseLatency    = "$context.responseLatency"
      integrationLatency = "$context.integrationLatency"
      integrationStatus  = "$context.integrationStatus"
      integrationError   = "$context.integrationErrorMessage"
      responseLength     = "$context.responseLength"
    })
  }

  tags = var.tags
}
