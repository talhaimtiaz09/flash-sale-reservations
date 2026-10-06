# Runbook 3: TTL return

**Question:** do holds that are never confirmed all come back to stock, exactly
once? Is an expired hold refused at confirm even while its item still exists?

**Status:** Not run.

## Setup

Follow [00-before-any-test.md](00-before-any-test.md), but apply with short
holds:

```bash
TF_VAR_alarm_email=you@example.com terraform apply -var hold_seconds=60
python scripts/seed_sale.py --table "$TABLE" --sale-id ttl-01 --units 200 --shards 4
```

## Run

**A. Sweeper on (normal).**

```bash
k6 run -e BASE_URL="$API" -e SALE_ID=ttl-01 -e UNITS=200 -e HOLD_SECONDS=60 loadtest/ttl-return.js
```

**B. Sweeper off: TTL and the stream only.** Seed `ttl-02`, then:

```bash
aws events disable-rule --name flash-sale-reservations-lab-sweeper
k6 run -e BASE_URL="$API" -e SALE_ID=ttl-02 -e UNITS=200 -e HOLD_SECONDS=60 -e WAIT_MINUTES=240 -e POLL_SECONDS=60 loadtest/ttl-return.js
aws events enable-rule --name flash-sale-reservations-lab-sweeper
```

Count the return markers; there must be exactly one per hold:

```bash
aws dynamodb scan --table-name "$TABLE" --select COUNT \
  --filter-expression "sale_id = :s AND begins_with(pk, :r)" \
  --expression-attribute-values '{":s":{"S":"ttl-01"},":r":{"S":"RETURN#"}}'
```

## Pass criteria

- `remaining_final` equals the units seeded, and `over_returned_polls` is 0.
- RETURN# markers = holds created.
- `late_confirm_accepted` is 0.
- The release DLQ is empty.

## Results

| Field | A: sweeper on | B: TTL + stream only |
|---|---|---|
| Date, commit | Not run | Not run |
| Holds created | Not run | Not run |
| Remaining at the end | Not run | Not run |
| RETURN# markers | Not run | Not run |
| Seconds after expiry until all back | Not run | Not run |
| Over-returned polls | Not run | Not run |
| Late confirm refused | Not run | Not run |
| Stream iterator age, max | Not run | Not run |
| DLQ messages | Not run | Not run |
| Results file | Not run | Not run |

## What happened

Not run.
