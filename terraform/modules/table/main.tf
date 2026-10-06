# The one DynamoDB table. Sales, stock shards, holds, idempotency keys and
# return markers share it, told apart by the pk prefix (see lambdas/shared/db.py).
#
# - On-demand, with a max_*_request_units cap: a runaway load test is
#   throttled instead of billed.
# - Streams with OLD_IMAGE: the release function needs the hold as it was
#   before TTL deleted it, nothing else.
# - TTL on `ttl`. It is cleanup only and can run hours late, so expiry itself
#   is always checked against expires_at.
# - live-holds is a sparse GSI. Only HELD holds carry held_bucket, so the
#   sweeper reads live holds and nothing else. held_bucket is spread over N
#   values so the index has no single hot partition key.

#trivy:ignore:AWS-0025 AWS-managed KMS key: no $1/month CMK and key policy for a lab table that holds no personal data. A CMK is a production upgrade.
resource "aws_dynamodb_table" "this" {
  name         = var.name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  attribute {
    name = "held_bucket"
    type = "S"
  }

  attribute {
    name = "expires_at"
    type = "N"
  }

  on_demand_throughput {
    max_read_request_units  = var.max_read_request_units
    max_write_request_units = var.max_write_request_units
  }

  global_secondary_index {
    name               = var.live_holds_index_name
    hash_key           = "held_bucket"
    range_key          = "expires_at"
    projection_type    = "INCLUDE"
    non_key_attributes = ["sale_id", "shard", "qty"]

    # Every hold write also writes the index. If the index throttles, the
    # table write is throttled with it, so it gets the same cap.
    on_demand_throughput {
      max_read_request_units  = var.max_read_request_units
      max_write_request_units = var.max_write_request_units
    }
  }

  stream_enabled   = true
  stream_view_type = "OLD_IMAGE"

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  # Without kms_key_arn this is the AWS-managed aws/dynamodb key.
  server_side_encryption {
    enabled = true
  }

  # Lab: destroyed every session. Production would turn this on.
  deletion_protection_enabled = false

  tags = var.tags
}
