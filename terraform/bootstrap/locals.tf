locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  state_bucket_name = coalesce(var.state_bucket_name, "${var.project}-tfstate-${local.account_id}")

  # Every name envs/<environment> creates starts with this. The apply role's
  # IAM, Lambda, DynamoDB, SQS, SNS, logs, alarm and EventBridge permissions
  # are scoped to it.
  workload_prefix = "${var.project}-${var.environment}"

  # State objects for this project, and the native-locking lock objects.
  state_objects_arn = "arn:${local.partition}:s3:::${local.state_bucket_name}/${var.project}/*"
  lock_objects_arn  = "arn:${local.partition}:s3:::${local.state_bucket_name}/${var.project}/*.tflock"

  github_oidc_host = "token.actions.githubusercontent.com"

  tags = {
    Project     = var.project
    Owner       = var.owner
    Environment = "bootstrap"
    ManagedBy   = "terraform"
  }
}
