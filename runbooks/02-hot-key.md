# Runbook 2: hot key

**Question:** how much does splitting one stock item into N shards change
throttling and latency under the same load?

**Status:** Not run.

## Setup

Follow [00-before-any-test.md](00-before-any-test.md), then seed two sales
with more units than the run can sell:

```bash
python scripts/seed_sale.py --table "$TABLE" --sale-id hot-1  --units 200000 --shards 1
python scripts/seed_sale.py --table "$TABLE" --sale-id hot-10 --units 200000 --shards 10
```

## Run

Same rate and duration for both. Wait five minutes between runs so the
dashboard shows them apart.

```bash
k6 run -e BASE_URL="$API" -e SALE_ID=hot-1  -e SHARDS=1  -e RATE=400 loadtest/hot-key.js
k6 run -e BASE_URL="$API" -e SALE_ID=hot-10 -e SHARDS=10 -e RATE=400 loadtest/hot-key.js
```

From the dashboard, for each run's window: table `WriteThrottleEvents`,
`TransactionConflict`, and reserve p95 duration.

## Pass criteria

There is no pass mark. The result is the comparison, published either way.

## Results

| Field | 1 shard | 10 shards |
|---|---|---|
| Date, commit | Not run | Not run |
| Rate, duration | Not run | Not run |
| Holds created | Not run | Not run |
| 429 answers | Not run | Not run |
| WriteThrottleEvents | Not run | Not run |
| TransactionConflict | Not run | Not run |
| p95, all responses | Not run | Not run |
| p95, 201 responses | Not run | Not run |
| Cost of the run | Not run | Not run |
| Results file | Not run | Not run |

## What happened

Not run.
