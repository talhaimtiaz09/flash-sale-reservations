// Test 2: hot key. The same steady burst against a sale with 1 stock shard,
// then against one with N shards. Compare throttling and p95.
//
// The sale is seeded with far more units than the run can sell, so every
// request competes for stock and none is answered "sold out".
//
//   python scripts/seed_sale.py --table "$TABLE" --sale-id hot-1 --units 200000 --shards 1
//   python scripts/seed_sale.py --table "$TABLE" --sale-id hot-10 --units 200000 --shards 10
//   k6 run -e BASE_URL="$API" -e SALE_ID=hot-1  -e SHARDS=1  loadtest/hot-key.js
//   k6 run -e BASE_URL="$API" -e SALE_ID=hot-10 -e SHARDS=10 loadtest/hot-key.js
//
// DynamoDB's side (WriteThrottleEvents, TransactionConflict) is on the
// dashboard; the runbook says which numbers to copy.

import { Counter, Trend } from 'k6/metrics';
import { count, env, envInt, newKey, reserve, writeResults } from './lib/api.js';

const SALE_ID = env('SALE_ID');
const SHARDS = envInt('SHARDS');
const RATE = envInt('RATE', 400); // requests per second
const DURATION = env('DURATION', '60s');

const created = new Counter('holds_created');
const busy = new Counter('busy_429');
const unexpected = new Counter('unexpected_status');
const createdMs = new Trend('reserve_201_ms', true);

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.ceil(RATE / 2),
      maxVUs: RATE * 4,
    },
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const res = reserve(SALE_ID, 1, newKey());
  if (res.status === 201) {
    created.add(1);
    createdMs.add(res.timings.duration);
  } else if (res.status === 429) {
    busy.add(1);
  } else {
    unexpected.add(1, { status: String(res.status) });
  }
}

export function handleSummary(data) {
  const reqs = data.metrics['http_reqs'] ? data.metrics['http_reqs'].values.count : 0;
  return writeResults(`hot-key-${SHARDS}-shards`, data, { SALE_ID, SHARDS, RATE, DURATION }, {
    requests: reqs,
    holds_created: count(data, 'holds_created'),
    busy_429: count(data, 'busy_429'),
    unexpected_status: count(data, 'unexpected_status'),
    p95_ms_all: data.metrics['http_req_duration'].values['p(95)'],
    p95_ms_201: data.metrics['reserve_201_ms'] ? data.metrics['reserve_201_ms'].values['p(95)'] : null,
  });
}
