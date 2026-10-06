output "state_bucket" {
  description = "State bucket name: pass as -backend-config=\"bucket=...\" and set as the TF_STATE_BUCKET repository variable."
  value       = aws_s3_bucket.state.id
}

output "state_kms_key_arn" {
  description = "KMS key encrypting the state bucket."
  value       = aws_kms_key.state.arn
}

output "github_oidc_provider_arn" {
  description = "The account's existing GitHub Actions OIDC provider (looked up, not managed here)."
  value       = data.aws_iam_openid_connect_provider.github.arn
}

output "plan_role_arn" {
  description = "Set as the AWS_PLAN_ROLE_ARN repository variable."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Set as the AWS_APPLY_ROLE_ARN repository (or lab environment) variable."
  value       = aws_iam_role.apply.arn
}
