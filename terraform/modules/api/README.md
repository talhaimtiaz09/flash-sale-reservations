# api

HTTP API with three routes, each wired to its own function (payload format
2.0) and allowed to invoke only that function.

| Route | Function |
|---|---|
| `POST /sales/{sale_id}/reserve` | reserve |
| `POST /holds/{hold_id}/confirm` | confirm |
| `GET /sales/{sale_id}` | get_sale |

The `$default` stage throttles at `throttle_rate_limit` / `throttle_burst_limit`
and writes JSON access logs. There is no authorizer.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | API name and log prefix |
| `invoke_arns`, `function_names` | map(string) | required | From `functions` |
| `throttle_rate_limit` | number | `500` | Requests per second |
| `throttle_burst_limit` | number | `1000` | Burst |
| `log_retention_days` | number | `14` | Access log retention |
| `tags` | map(string) | `{}` | Tags |

## Outputs

| Name | Description |
|---|---|
| `url` | Base URL |
| `api_id`, `stage_name` | CloudWatch dimensions |
| `access_log_group_name` | Access log group |
