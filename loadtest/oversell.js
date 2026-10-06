// Test 1: oversell. 10,000 buyers race for 1,000 units.
//
// Pass: holds created == units, and the sale's remaining stock ends at
// units - holds (never below zero). Any hold beyond the stock is an oversell.
//
//   python scripts/seed_sale.py --table "$TABLE" --sale-id oversell-01 --units 1000 --shards 10
//   k6 run -e BASE_URL="$API" -e SALE_ID=oversell-01 -e UNITS=1000 loadtest/oversell.js

import { sleep } from 'k6';
import { Counter, Gauge } from 'k6/metrics';
import { count, env, envInt, gauge, getSale, newKey, reserve, retryAfterSeconds, writeResults } from './lib/api.js';

const SALE_ID = env('SALE_ID');
const UNITS = envInt('UNITS');
const BUYERS = envInt('BUYERS', 10000);
const VUS = envInt('VUS', 500);
const ATTEMPTS = envInt('ATTEMPTS', 3); // per buyer, same Idempotency-Key, only after a 429

const holdsCreated = new Counter('holds_created');
const replayed = new Counter('replayed');
const soldOut = new Counter('sold_out');
const gaveUp = new Counter('gave_up_after_429');
const unexpected = new Counter('unexpected_status');
const remainingAfter = new Gauge('remaining_after');

export const options = {
  scenarios: {
    buyers: { executor: 'shared-iterations', vus: VUS, iterations: BUYERS, maxDuration: '10m' },
  },
};

export default function () {
  const key = newKey();
  for (let attempt = 1; attempt <= ATTEMPTS; attempt++) {
    const res = reserve(SALE_ID, 1, key);
    if (res.status === 429) {
      sleep(retryAfterSeconds(res) * (0.5 + Math.random())); // jitter, so retries don't arrive together
      continue;
    }
    if (res.status === 201) holdsCreated.add(1);
    else if (res.status === 200) replayed.add(1); // an earlier attempt got through after all
    else if (res.status === 409) soldOut.add(1);
    else unexpected.add(1, { status: String(res.status) });
    return;
  }
  gaveUp.add(1);
}

export function teardown() {
  const sale = getSale(SALE_ID);
  if (sale) remainingAfter.add(sale.remaining);
}

export function handleSummary(data) {
  const holds = count(data, 'holds_created') + count(data, 'replayed');
  const remaining = gauge(data, 'remaining_after');
  return writeResults('oversell', data, { SALE_ID, UNITS, BUYERS, VUS, ATTEMPTS }, {
    holds,
    oversold: Math.max(0, holds - UNITS),
    remaining_after: remaining,
    stock_matches_holds: remaining !== null && UNITS - remaining === holds,
    sold_out_answers: count(data, 'sold_out'),
    gave_up_after_429: count(data, 'gave_up_after_429'),
    unexpected_status: count(data, 'unexpected_status'),
  });
}
