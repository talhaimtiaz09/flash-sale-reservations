// Test 4: idempotency. One request, sent 50 times at once with the same
// Idempotency-Key, must create one hold. Repeated for KEYS different keys.
//
//   python scripts/seed_sale.py --table "$TABLE" --sale-id idem-01 --units 1000 --shards 10
//   k6 run -e BASE_URL="$API" -e SALE_ID=idem-01 -e UNITS=1000 loadtest/idempotency.js
//
// Pass: extra_holds == 0, and stock went down by exactly KEYS.

import http from 'k6/http';
import { Counter, Gauge } from 'k6/metrics';
import { count, env, envInt, gauge, getSale, newKey, reserveRequest, writeResults } from './lib/api.js';

const SALE_ID = env('SALE_ID');
const UNITS = envInt('UNITS');
const REPLAYS = envInt('REPLAYS', 50);
const KEYS = envInt('KEYS', 20);

const keysTested = new Counter('keys_tested');
const extraHolds = new Counter('extra_holds');
const noHold = new Counter('keys_without_hold');
const created = new Counter('answered_201');
const replayed = new Counter('answered_200');
const busy = new Counter('answered_429');
const unexpected = new Counter('unexpected_status');
const remainingAfter = new Gauge('remaining_after');

export const options = {
  // One VU fires all replays of a key in parallel with http.batch.
  scenarios: { replay: { executor: 'per-vu-iterations', vus: 1, iterations: KEYS, maxDuration: '5m' } },
  batch: REPLAYS,
  batchPerHost: REPLAYS,
};

export default function () {
  const key = newKey();
  const req = reserveRequest(SALE_ID, 1, key);
  const responses = http.batch(Array.from({ length: REPLAYS }, () => ['POST', req.url, req.body, req.params]));

  const holdIds = new Set();
  for (const res of responses) {
    if (res.status === 201) created.add(1);
    else if (res.status === 200) replayed.add(1);
    else if (res.status === 429) busy.add(1);
    else unexpected.add(1, { status: String(res.status) });
    if (res.status === 200 || res.status === 201) holdIds.add(res.json('hold_id'));
  }
  keysTested.add(1);
  if (holdIds.size === 0) noHold.add(1);
  if (holdIds.size > 1) extraHolds.add(holdIds.size - 1);
}

export function teardown() {
  const sale = getSale(SALE_ID);
  if (sale) remainingAfter.add(sale.remaining);
}

export function handleSummary(data) {
  const remaining = gauge(data, 'remaining_after');
  const keys = count(data, 'keys_tested');
  return writeResults('idempotency', data, { SALE_ID, UNITS, REPLAYS, KEYS }, {
    keys_tested: keys,
    extra_holds: count(data, 'extra_holds'),
    keys_without_hold: count(data, 'keys_without_hold'),
    units_taken: remaining === null ? null : UNITS - remaining,
    // Keys whose every replay got a 429 never made a hold, so they took no stock.
    stock_matches_keys: remaining !== null && UNITS - remaining === keys - count(data, 'keys_without_hold'),
    answered_201: count(data, 'answered_201'),
    answered_200: count(data, 'answered_200'),
    answered_429: count(data, 'answered_429'),
    unexpected_status: count(data, 'unexpected_status'),
  });
}
