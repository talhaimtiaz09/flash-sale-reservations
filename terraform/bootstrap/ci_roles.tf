# GitHub Actions -> AWS through OIDC. No AWS keys in GitHub. Each role trusts
# one repo and one exact `sub` claim:
#
#   plan   repo:<repo>:pull_request         PR jobs (read-only + state lock)
#   apply  repo:<repo>:environment:<env>    jobs with `environment: lab`
#
# A job that declares `environment:` gets the environment form of `sub`, NOT
# the ref form, so the apply role is bound to the GitHub Environment. Restrict
# that environment to the main branch and require a reviewer in repo settings.

# ---------------------------------------------------------------------------
# OIDC provider: looked up, not created
# ---------------------------------------------------------------------------

# An account has at most one OIDC provider per URL, and this account's GitHub
# provider already exists: immutable-ec2-web-tier's bootstrap created it.
# Declaring it here as a resource would fail with EntityAlreadyExists, and
# managing it from two repos would let either one delete it from under the
# other. So it is read by URL. If the account has none yet, create it once
# (aws iam create-open-id-connect-provider) before applying this.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://${local.github_oidc_host}"
}

data "aws_iam_policy_document" "github_trust" {
  for_each = {
    plan  = "repo:${var.github_repository}:pull_request"
    apply = "repo:${var.github_repository}:environment:${var.github_environment}"
  }

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = [each.value]
    }
  }
}

# ---------------------------------------------------------------------------
# Plan role: read-only, plus what `terraform plan` writes (the lock object)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "plan" {
  name                 = "${var.project}-gha-plan"
  description          = "GitHub Actions: terraform plan on pull requests (read-only)."
  assume_role_policy   = data.aws_iam_policy_document.github_trust["plan"].json
  max_session_duration = 3600

  tags = local.tags
}

# Plan refreshes every resource, so it needs broad read. ReadOnlyAccess is the
# deliberate trade-off over a hand-maintained Describe* list.
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_state" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "ReadState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.state_objects_arn]
  }

  # Native S3 locking writes <key>.tflock even during plan and deletes it after.
  statement {
    sid       = "WriteLockObjectOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = [local.lock_objects_arn]
  }

  # Decrypt state; Encrypt/GenerateDataKey to write the SSE-KMS lock object.
  statement {
    sid       = "StateKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state-read-lock"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state.json
}

# ---------------------------------------------------------------------------
# Apply role: read-only plus write access to the services envs/lab uses
# ---------------------------------------------------------------------------

resource "aws_iam_role" "apply" {
  name                 = "${var.project}-gha-apply"
  description          = "GitHub Actions: terraform apply for envs/${var.environment} (GitHub Environment ${var.github_environment})."
  assume_role_policy   = data.aws_iam_policy_document.github_trust["apply"].json
  max_session_duration = 3600

  tags = local.tags
}

# Same reason as the plan role: refresh reads everything Terraform manages.
resource "aws_iam_role_policy_attachment" "apply_readonly" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "apply_state" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "ReadWriteState"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.state_objects_arn]
  }

  statement {
    sid       = "StateKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role_policy" "apply_state" {
  name   = "terraform-state-read-write"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_state.json
}

# The workload: table, functions, API, queue, schedule. Scoped to
# workload-prefixed names wherever the service has names in its ARNs.
data "aws_iam_policy_document" "apply_workload" {
  statement {
    sid    = "DynamoDbTable"
    effect = "Allow"
    actions = [
      "dynamodb:CreateTable",
      "dynamodb:DeleteTable",
      "dynamodb:UpdateTable",
      "dynamodb:UpdateTimeToLive",
      "dynamodb:UpdateContinuousBackups",
      "dynamodb:TagResource",
      "dynamodb:UntagResource",
    ]
    resources = [
      "arn:${local.partition}:dynamodb:${var.region}:${local.account_id}:table/${local.workload_prefix}",
      "arn:${local.partition}:dynamodb:${var.region}:${local.account_id}:table/${local.workload_prefix}/index/*",
    ]
  }

  statement {
    sid    = "LambdaFunctions"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:PutFunctionConcurrency",
      "lambda:DeleteFunctionConcurrency",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:TagResource",
      "lambda:UntagResource",
    ]
    resources = ["arn:${local.partition}:lambda:${var.region}:${local.account_id}:function:${local.workload_prefix}-*"]
  }

  # Event source mapping ARNs are random UUIDs, so these are limited by the
  # function the mapping points at instead.
  statement {
    sid    = "StreamMapping"
    effect = "Allow"
    actions = [
      "lambda:CreateEventSourceMapping",
      "lambda:UpdateEventSourceMapping",
      "lambda:DeleteEventSourceMapping",
    ]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "lambda:FunctionArn"
      values   = ["arn:${local.partition}:lambda:${var.region}:${local.account_id}:function:${local.workload_prefix}-*"]
    }
  }

  # HTTP API IDs are random, so this is region-wide within API Gateway.
  statement {
    sid    = "HttpApi"
    effect = "Allow"
    actions = [
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:PATCH",
      "apigateway:DELETE",
      "apigateway:TagResource",
      "apigateway:UntagResource",
    ]
    resources = [
      "arn:${local.partition}:apigateway:${var.region}::/apis",
      "arn:${local.partition}:apigateway:${var.region}::/apis/*",
      "arn:${local.partition}:apigateway:${var.region}::/tags/*",
    ]
  }

  statement {
    sid    = "ReleaseDlq"
    effect = "Allow"
    actions = [
      "sqs:CreateQueue",
      "sqs:DeleteQueue",
      "sqs:SetQueueAttributes",
      "sqs:TagQueue",
      "sqs:UntagQueue",
    ]
    resources = ["arn:${local.partition}:sqs:${var.region}:${local.account_id}:${local.workload_prefix}-*"]
  }

  statement {
    sid    = "SweeperSchedule"
    effect = "Allow"
    actions = [
      "events:PutRule",
      "events:DeleteRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:TagResource",
      "events:UntagResource",
    ]
    resources = ["arn:${local.partition}:events:${var.region}:${local.account_id}:rule/${local.workload_prefix}-*"]
  }
}

resource "aws_iam_policy" "apply_workload" {
  name        = "${var.project}-gha-apply-workload"
  description = "Apply role: DynamoDB table, Lambda functions and stream mapping, HTTP API, SQS DLQ, EventBridge rule."
  policy      = data.aws_iam_policy_document.apply_workload.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "apply_workload" {
  role       = aws_iam_role.apply.name
  policy_arn = aws_iam_policy.apply_workload.arn
}

# Observability: alarms, dashboard, log groups, SNS topic.
data "aws_iam_policy_document" "apply_observability" {
  statement {
    sid    = "CloudWatchAlarms"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
    ]
    resources = ["arn:${local.partition}:cloudwatch:${var.region}:${local.account_id}:alarm:${local.workload_prefix}-*"]
  }

  statement {
    sid       = "CloudWatchDashboards"
    effect    = "Allow"
    actions   = ["cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards"]
    resources = ["arn:${local.partition}:cloudwatch::${local.account_id}:dashboard/${local.workload_prefix}*"]
  }

  statement {
    sid    = "LogGroups"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:TagLogGroup",
      "logs:UntagLogGroup",
    ]
    resources = [
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/${local.workload_prefix}-*",
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/${local.workload_prefix}-*:*",
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/${local.workload_prefix}/*",
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/${local.workload_prefix}/*:*",
    ]
  }

  # HTTP API access logging is set up with the caller's permissions through
  # CloudWatch Logs log delivery, which has no resource-level permissions.
  statement {
    sid    = "ApiAccessLogDelivery"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AlertTopics"
    effect = "Allow"
    actions = [
      "sns:CreateTopic",
      "sns:DeleteTopic",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
      "sns:Unsubscribe",
      "sns:SetSubscriptionAttributes",
      "sns:TagResource",
      "sns:UntagResource",
    ]
    resources = ["arn:${local.partition}:sns:${var.region}:${local.account_id}:${local.workload_prefix}-*"]
  }
}

resource "aws_iam_policy" "apply_observability" {
  name        = "${var.project}-gha-apply-observability"
  description = "Apply role: CloudWatch alarms and dashboard, log groups and API log delivery, SNS."
  policy      = data.aws_iam_policy_document.apply_observability.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "apply_observability" {
  role       = aws_iam_role.apply.name
  policy_arn = aws_iam_policy.apply_observability.arn
}

# IAM: only workload-prefixed roles, so the apply role can't touch the CI
# roles ("<project>-gha-*") or anything else. Residual risk, accepted for the
# lab: inline role policies can't be content-constrained. Production would add
# a permissions boundary condition.
#trivy:ignore:AWS-0342 PassRole is required to create functions with their execution roles; limited to workload-prefixed roles and Lambda.
data "aws_iam_policy_document" "apply_iam" {
  statement {
    sid    = "WorkloadRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.workload_prefix}-*"]
  }

  statement {
    sid       = "PassWorkloadRolesToLambda"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.workload_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "apply_iam" {
  name        = "${var.project}-gha-apply-iam"
  description = "Apply role: IAM limited to ${local.workload_prefix}-* roles, passed only to Lambda."
  policy      = data.aws_iam_policy_document.apply_iam.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "apply_iam" {
  role       = aws_iam_role.apply.name
  policy_arn = aws_iam_policy.apply_iam.arn
}
