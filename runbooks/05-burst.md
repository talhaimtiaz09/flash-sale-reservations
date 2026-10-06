# Runbook 5: burst

**Question:** when traffic jumps from nothing to a peak in seconds, does the
system say no with 429s, or fall over with 5xx? What do cold starts cost?

**Status:** Not run.

## Setup

Follow [00-before-any-test.md](00-before-any-test.md). Write down the API
stage limits (`api_throttle_rate_limit`, `api_throttle_burst_limit`), the
account's Lambda concurrency and `reserve_reserved_concurrency`. Then:

```bash
python scripts/seed_sale.py --table "$TABLE" --sale-id burst-01 --units 500000 --shards 20
```

Let the functions go cold first: no traffic for 15 minutes or more.

## Run

```bash
k6 run -e BASE_URL="$API" -e SALE_ID=burst-01 -e PEAK=2000 loadtest/burst.js
```

Cold starts, from CloudWatch Logs Insights on `/aws/lambda/flash-sale-reservations-lab-reserve`:

```
filter type = "platform.report" and ispresent(record.metrics.initDurationMs)
| stats count(*) as cold_starts, avg(record.metrics.initDurationMs) as avg_init_ms,
        max(record.metrics.initDurationMs) as max_init_ms by bin(10s)
```

Who said no: compare k6's 429 count with the API access logs (`status` 429
with no `integrationStatus` means API Gateway throttled before the function
ran) and the `Throttles` metric on reserve.

## Pass criteria

- No 5xx, or every 5xx explained.
- 429s come with `Retry-After`.

## Results

| Field | Value |
|---|---|
| Date, commit | Not run |
| Limits: stage rate / burst, Lambda quota, reserved | Not run |
| Requests | Not run |
| Answers: 201 / 429 / 5xx / other | Not run |
| 429s from API Gateway vs from reserve | Not run |
| 5xx rate | Not run |
| p95, all / first 10 s | Not run |
| Cold starts, max init duration | Not run |
| Lambda throttles | Not run |
| Cost of the run | Not run |
| Results file | Not run |

## What happened

Not run.
