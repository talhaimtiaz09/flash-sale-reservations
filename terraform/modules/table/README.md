# table

The single DynamoDB table. Sales, stock shards, holds, idempotency keys and
return markers share it, told apart by the `pk` prefix.

- **On-demand with a cap:** `on_demand_throughput` on the table and the index,
  so a runaway load test is throttled instead of billed.
- **Streams, `OLD_IMAGE`:** the release function needs the hold as it was
  before TTL deleted it.
- **TTL on `ttl`:** cleanup only. It can run hours late, so the code checks
  `expires_at` itself.
- **`live-holds` GSI:** sparse. Only `HELD` holds carry `held_bucket`, so the
  sweeper reads live holds and nothing else. Keyed `held_bucket` +
  `expires_at`, projecting `sale_id`, `shard` and `qty`.
- PITR on, SSE with the AWS-managed key, no deletion protection (lab).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Table name |
| `live_holds_index_name` | string | `live-holds` | Sparse GSI name |
| `max_read_request_units` | number | `4000` | On-demand read cap (table and index) |
| `max_write_request_units` | number | `4000` | On-demand write cap (table and index) |
| `tags` | map(string) | `{}` | Tags |

## Outputs

| Name | Description |
|---|---|
| `name`, `arn` | Table name and ARN |
| `stream_arn` | Stream ARN |
| `live_holds_index_name`, `live_holds_index_arn` | Sparse index |
