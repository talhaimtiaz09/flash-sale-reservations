// Test 5: burst. Traffic jumps from nothing to PEAK requests per second in a
// few seconds. The question is how the system says no: 429s from API Gateway
// or the function (fine), or 5xx (not fine). Records p95, and p95 in the first
// 10 seconds, when cold starts land.
//
//   python scripts/seed_sale.py --table "$TABLE" --sale-id burst-01 --units 500000 --shards 20
//   k6 run -e BASE_URL="$API" -e SALE_ID=burst-01 loadtest/burst.js
//
// Cold starts come from the reserve log group (Logs Insights query in the
// runbook), not from k6.

import { Counter, Trend } from 'k6/metrics';
import { count, env, envInt, newKey, reserve, writeResults } from './lib/api.js';

const SALE_ID = env('SALE_ID');
const PEAK = envInt('PEAK', 2000);
const RAMP = env('RAMP', '5s');
const HOLD = env('HOLD', '30s');

const created = new Counter('answered_201');
const throttled = new Counter('answered_429');
const serverErrors = new Counter('answered_5xx');
const other = new Counter('answered_other');
const firstTen = new Trend('reserve_ms_first_10s', true);

export const options = {
  scenarios: {
    burst: {
      executor: 'ramping-arrival-rate',
      startRate: 0,
      timeUnit: '1s',
      preAllocatedVUs: 500,
      maxVUs: 4000,
      stages: [
        { target: PEAK, duration: RAMP },
        { target: PEAK, duration: HOLD },
        { target: 0, duration: '5s' },
      ],
    },
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

export function setup() {
  return { start: Date.now() };
}

export default function (ctx) {
  const res = reserve(SALE_ID, 1, newKey());
  if (Date.now() - ctx.start < 10000) firstTen.add(res.timings.duration);
  if (res.status === 201) created.add(1);
  else if (res.status === 429) throttled.add(1);
  else if (res.status >= 500) serverErrors.add(1, { status: String(res.status) });
  else other.add(1, { status: String(res.status) });
}

export function handleSummary(data) {
  const total = data.metrics['http_reqs'] ? data.metrics['http_reqs'].values.count : 0;
  const errors = count(data, 'answered_5xx');
  return writeResults('burst', data, { SALE_ID, PEAK, RAMP, HOLD }, {
    requests: total,
    answered_201: count(data, 'answered_201'),
    answered_429: count(data, 'answered_429'),
    answered_5xx: errors,
    answered_other: count(data, 'answered_other'),
    error_rate_5xx: total ? errors / total : null,
    p95_ms_all: data.metrics['http_req_duration'].values['p(95)'],
    p95_ms_first_10s: data.metrics['reserve_ms_first_10s'] ? data.metrics['reserve_ms_first_10s'].values['p(95)'] : null,
  });
}
