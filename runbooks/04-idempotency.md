# Runbook 4: idempotency

**Question:** if one request is sent 50 times at once with the same
Idempotency-Key, is exactly one hold created?

**Status:** Not run.

## Setup

Follow [00-before-any-test.md](00-before-any-test.md), then:

```bash
python scripts/seed_sale.py --table "$TABLE" --sale-id idem-01 --units 1000 --shards 10
```

## Run

```bash
k6 run -e BASE_URL="$API" -e SALE_ID=idem-01 -e UNITS=1000 -e REPLAYS=50 -e KEYS=20 loadtest/idempotency.js
```

## Pass criteria

- `extra_holds` is 0.
- `stock_matches_keys` is true: stock went down once per key that got a hold.

## Results

| Field | Value |
|---|---|
| Date, commit | Not run |
| Keys x replays | Not run |
| Extra holds | Not run |
| Keys without a hold (all 429) | Not run |
| Units taken | Not run |
| Answers: 201 / 200 / 429 / other | Not run |
| Results file | Not run |

## What happened

Not run.
