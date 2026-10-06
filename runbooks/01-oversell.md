# Runbook 1: oversell

**Question:** with 10,000 buyers racing for 1,000 units, does any unit sell twice?

**Status:** Not run.

## Setup

Follow [00-before-any-test.md](00-before-any-test.md), then:

```bash
python scripts/seed_sale.py --table "$TABLE" --sale-id oversell-01 --units 1000 --shards 10
```

## Run

```bash
k6 run -e BASE_URL="$API" -e SALE_ID=oversell-01 -e UNITS=1000 loadtest/oversell.js
```

Cross-check in DynamoDB that the number of holds matches k6's count:

```bash
aws dynamodb scan --table-name "$TABLE" --select COUNT \
  --filter-expression "sale_id = :s AND begins_with(pk, :h)" \
  --expression-attribute-values '{":s":{"S":"oversell-01"},":h":{"S":"HOLD#"}}'
```

## Pass criteria

- `oversold` is 0.
- Holds in DynamoDB = holds counted by k6 = 1,000 - remaining.
- `remaining_after` is 0 or more.

## Results

| Field | Value |
|---|---|
| Date, commit | Not run |
| Lambda concurrency quota | Not run |
| Holds created (k6 / DynamoDB) | Not run |
| Oversold | Not run |
| Remaining after | Not run |
| Sold-out answers / gave up after 429 | Not run |
| Unexpected statuses | Not run |
| p95 reserve latency | Not run |
| Cost of the run | Not run |
| Results file | Not run |

## What happened

Not run.
