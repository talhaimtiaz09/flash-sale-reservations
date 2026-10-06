// Test 3: TTL return. Holds that are never confirmed must all come back to
// stock, exactly once, and an expired hold must not be confirmable even while
// its item still exists.
//
// Apply envs/lab with hold_seconds = 60 first (lab.tfvars.example).
//
//   python scripts/seed_sale.py --table "$TABLE" --sale-id ttl-01 --units 200 --shards 4
//   k6 run -e BASE_URL="$API" -e SALE_ID=ttl-01 -e UNITS=200 -e HOLD_SECONDS=60 loadtest/ttl-return.js
//
// With the sweeper running, units come back within about a minute of expiry.
// The runbook's variant B disables the sweeper's rule so only TTL deletes and
// the stream return stock; then set WAIT_MINUTES to a few hours.

import { sleep } from 'k6';
import { Counter, Gauge } from 'k6/metrics';
import { confirm, count, env, envInt, gauge, getSale, newKey, reserve, writeResults } from './lib/api.js';

const SALE_ID = env('SALE_ID');
const UNITS = envInt('UNITS');
const HOLD_SECONDS = envInt('HOLD_SECONDS');
const WAIT_MINUTES = envInt('WAIT_MINUTES', 15);
const POLL_SECONDS = envInt('POLL_SECONDS', 10);

const held = new Counter('holds_created');
const lateConfirmRejected = new Counter('late_confirm_rejected');
const lateConfirmAccepted = new Counter('late_confirm_accepted');
const overReturned = new Counter('over_returned_polls');
const secondsToFull = new Gauge('seconds_to_full_return');
const remainingFinal = new Gauge('remaining_final');

export const options = {
  scenarios: {
    // Takes every unit but one, in single-unit holds, and confirms none.
    hold: {
      executor: 'shared-iterations',
      exec: 'holdOne',
      vus: 20,
      iterations: UNITS - 1,
      maxDuration: '2m',
    },
    // Takes the last unit, waits past expiry, tries to confirm it, then
    // watches the sale until every unit is back.
    watch: {
      executor: 'per-vu-iterations',
      exec: 'watch',
      vus: 1,
      iterations: 1,
      maxDuration: `${HOLD_SECONDS + WAIT_MINUTES * 60 + 120}s`,
    },
  },
};

export function holdOne() {
  if (reserve(SALE_ID, 1, newKey()).status === 201) held.add(1);
}

export function watch() {
  const res = reserve(SALE_ID, 1, newKey());
  if (res.status !== 201) return;
  held.add(1);
  const holdId = res.json('hold_id');
  const start = Date.now();

  sleep(HOLD_SECONDS + 2);
  const late = confirm(holdId);
  if (late.status === 409 || late.status === 404) lateConfirmRejected.add(1);
  else lateConfirmAccepted.add(1);

  const deadline = Date.now() + WAIT_MINUTES * 60 * 1000;
  let sale = null;
  while (Date.now() < deadline) {
    sale = getSale(SALE_ID);
    if (sale && sale.remaining > UNITS) overReturned.add(1);
    if (sale && sale.remaining >= UNITS) {
      secondsToFull.add((Date.now() - start) / 1000 - HOLD_SECONDS);
      break;
    }
    sleep(POLL_SECONDS);
  }
  if (sale) remainingFinal.add(sale.remaining);
}

export function handleSummary(data) {
  const remaining = gauge(data, 'remaining_final');
  return writeResults('ttl-return', data, { SALE_ID, UNITS, HOLD_SECONDS, WAIT_MINUTES }, {
    holds_created: count(data, 'holds_created'),
    remaining_final: remaining,
    all_returned: remaining === UNITS,
    over_returned_polls: count(data, 'over_returned_polls'),
    seconds_after_expiry_to_full_return: gauge(data, 'seconds_to_full_return'),
    late_confirm_rejected: count(data, 'late_confirm_rejected'),
    late_confirm_accepted: count(data, 'late_confirm_accepted'),
  });
}
