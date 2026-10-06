# functions

The five Lambda functions (Python 3.13, arm64, boto3 only) and what they need.

- **Packaging:** `archive_file` zips `lambdas/<name>/<name>.py` with
  `lambdas/shared/` into `<root>/.build/<name>.zip` at plan time.
- **IAM:** one role per function. Table access is limited by
  `dynamodb:LeadingKeys` to the `pk` prefixes each function touches: reserve
  reads `SALE#`/`IDEM#`/`HOLD#`, updates `SALE#` and puts `HOLD#`/`IDEM#`;
  confirm only updates `HOLD#`; get_sale only queries `SALE#`; release
  updates `SALE#` and puts `RETURN#`; sweeper also deletes `HOLD#` and
  queries the index. Logs go only to the function's own log group.
- **release:** stream event source mapping, filtered to TTL deletes of `HELD`
  holds, with `ReportBatchItemFailures`, bisect on error, 5 retries, a 1 h
  record age limit and an SQS DLQ on failure.
- **sweeper:** EventBridge rule, `rate(1 minute)` by default.
- **Reserved concurrency:** `reserve_reserved_concurrency`, null by default
  (see the root README for why).
- JSON logs with a retention period; X-Ray off.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Name prefix |
| `source_dir` | string | required | Path to `lambdas/` |
| `table_name`, `table_arn`, `stream_arn` | string | required | From `table` |
| `live_holds_index_name`, `live_holds_index_arn` | string | required | From `table` |
| `hold_seconds` | number | `600` | Hold lifetime |
| `hold_buckets` | number | `10` | `held_bucket` values |
| `max_qty` | number | `4` | Most units per reservation |
| `sweep_schedule` | string | `rate(1 minute)` | Sweeper schedule |
| `memory_mb` | number | `256` | Memory per function |
| `reserve_reserved_concurrency` | number | `null` | Reserved concurrency for reserve |
| `log_retention_days` | number | `14` | Log retention |
| `tags` | map(string) | `{}` | Tags |

## Outputs

| Name | Description |
|---|---|
| `function_names`, `invoke_arns`, `log_group_names` | Maps keyed by function |
| `release_dlq_name`, `release_dlq_url` | The release DLQ |
