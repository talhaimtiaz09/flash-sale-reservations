# alarms

An SNS email topic, the alarms below and one dashboard with the numbers the
load tests read.

| Alarm | Fires when |
|---|---|
| `api-5xx` | 5+ API 5xx responses in a minute |
| `<function>-errors` | any function error (all five) |
| `<function>-throttles` | Lambda throttles a function (all five) |
| `dynamodb-throttles` | table read/write or index write throttle events |
| `stream-iterator-age` | release is 60 s+ behind the stream for 5 minutes |
| `release-dlq` | a stream batch failed after all retries |

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Name prefix |
| `alarm_email` | string | required | Subscribed email |
| `api_id`, `api_stage` | string | required | From `api` |
| `function_names` | map(string) | required | From `functions` |
| `table_name`, `live_holds_index_name` | string | required | From `table` |
| `release_dlq_name` | string | required | From `functions` |
| `api_5xx_threshold` | number | `5` | 5xx per minute |
| `iterator_age_threshold_seconds` | number | `60` | Stream lag |
| `tags` | map(string) | `{}` | Tags |

## Outputs

| Name | Description |
|---|---|
| `alerts_topic_arn` | SNS topic |
| `dashboard_name` | Dashboard |
