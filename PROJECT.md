# Project: Flash-Sale Reservations on Lambda and DynamoDB

A small reservation service for a fixed stock of units (tickets, a limited
drop, conference seats) sold to far more buyers than there are units, all in
the same few seconds. With ten users it's CRUD. With ten thousand it hits
overselling, a hot DynamoDB key, late TTL deletes and retry storms. The
project solves those, load-tests them, and publishes the numbers.

**Running cost:** near $0 idle (on-demand, no always-on compute). A load-test
run costs cents; record the real figure. Destroy `envs/lab` between sessions.

**Honesty rule:** no real users. Every scale claim comes from a k6 run that
anyone can rerun from the repo. Until a test is run, the page says "Not run".

---

## API

| Route | What it does |
|---|---|
| `POST /sales/{sale_id}/reserve` | Body `{ "qty": n }`, header `Idempotency-Key`. Holds n units for ~10 minutes. 201 with hold, 409 sold out, 429 throttled. |
| `POST /holds/{hold_id}/confirm` | Turns a live hold into an order. 409 if expired or already confirmed. |
| `GET /sales/{sale_id}` | Remaining stock (sum of shards) and status. |

Sales are created by `scripts/seed_sale.py` (sale id, total units, shard count),
not through the public API.

## Services

- API Gateway HTTP API: stage throttling (rate and burst as variables), access logs.
- Lambda, Python 3.13 on arm64: `reserve`, `confirm`, `get_sale`, `release`
  (DynamoDB Streams consumer), `sweeper` (EventBridge schedule).
- DynamoDB: one table, on-demand, Streams (old image), TTL, PITR, a capped
  `on_demand_throughput` so a runaway test can't run up a bill.
- CloudWatch: alarms (5xx, Lambda errors and throttles, DynamoDB throttled
  requests, stream iterator age), one dashboard, SNS email.
- IAM: one role per function, scoped to the table and its stream / index ARNs.
- Terraform with remote state, CI over GitHub OIDC (same pattern as
  `immutable-ec2-web-tier`).

Out of scope: payments (confirm is a stand-in), Cognito, a frontend, Step
Functions, Kinesis, multi-region, DAX.

## Data model (single table)

| PK | SK | Attributes |
|---|---|---|
| `SALE#{id}` | `META` | total, shard_count, created_at |
| `SALE#{id}` | `SHARD#{n}` | stock |
| `HOLD#{id}` | `HOLD` | sale_id, shard, qty, status (HELD / CONFIRMED), expires_at, `ttl` |
| `IDEM#{key}` | `IDEM` | hold_id, `ttl` (24h) |
| `RETURN#{hold_id}` | `RETURN` | marker so stock is returned once, `ttl` |

A sparse GSI holds only live holds (attribute present while status is HELD),
keyed for the sweeper to find expired ones.

## The five problems (the write-up is built on these)

1. **Overselling.** Read-then-write lets two buyers take the last unit. Fix:
   one conditional update, `stock >= :qty`, inside a transaction with the hold
   and idempotency writes. Test: 10,000 buyers vs 1,000 units, count oversold.
2. **The hot item.** Every buyer writes the same item; one partition takes
   about 1,000 write units a second, and a transaction costs double. Fix: split
   stock across N shard items, pick one at random, try others on a stock
   failure. Trade-off: near sell-out, the last units are scattered and "sold
   out" needs every shard checked. Test: same burst with shard_count 1 vs N,
   compare throttled requests and p95.
3. **Late TTL.** TTL deletes can lag expiry by hours. Fix: confirm checks
   `expires_at` itself; the stream consumer returns stock on TTL deletes of
   HELD holds; the sweeper deletes expired holds and returns their stock.
   Stream batches are retried, so a return must be idempotent: write the
   `RETURN#` marker with `attribute_not_exists` in the same transaction as the
   increment. Test: holds that expire unconfirmed all come back, exactly once.
4. **Retries and double clicks.** Same `Idempotency-Key` returns the same
   hold, never a second one. Test: replay one request 50 times, one hold.
5. **Failing politely.** API Gateway throttling and optional reserved
   concurrency give 429s instead of melting DynamoDB or the account's Lambda
   limit. New accounts can have a Lambda concurrency quota as low as 10, and
   reserved concurrency must leave 100 unreserved, so reserved concurrency is a
   variable defaulting to null and the README says why. Test: error rate, p95
   and cold starts at the start of the burst.

## Load tests (k6, in `loadtest/`)

Written now, run later. Each produces a results file and a runbook entry:
`oversell`, `hot-key` (shards 1 vs N), `ttl-return`, `idempotency`, `burst`.
Results are published as measured, including misses.

## Repo layout

```
lambdas/            one folder per function + shared module, unit tests
terraform/
  bootstrap/        state bucket, CI roles, budget (reuses the account's
                    existing GitHub OIDC provider)
  modules/          api, functions, table, alarms (or similar, kept small)
  envs/lab/
scripts/seed_sale.py
loadtest/           k6 scripts
runbooks/           one per test, filled only from real runs
docs/index.html     GitHub Pages project page; diagrams in docs/images/
prompts/diagrams.md ChatGPT prompts for those diagrams
.github/workflows/  terraform (checks, plan on PR, approved apply), lambdas (ruff, pytest)
```

## Page and writing rules

- Same theme and structure as `immutable-ec2-web-tier/docs/index.html`
  (portfolio case-study style). No text, ASCII or SVG diagrams: image slots
  only, with prompts in `prompts/diagrams.md` in the same format as that repo.
- Voice: first person, plain English, short sentences, specific numbers over
  adjectives. No "passionate", "leverage", "robust", "seamless", no em-dash
  heavy rhythm, no marketing fluff.
- Status table states what is written vs what is run. No measured numbers
  until they exist.
- No mention of AI assistants or their vendors anywhere: files, commits, PRs.
