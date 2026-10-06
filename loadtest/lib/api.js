// Shared helpers for the k6 tests: API calls, env handling, results files.
//
// Every test reads BASE_URL (terraform output api_url) and SALE_ID (a sale
// seeded with scripts/seed_sale.py for that run). Run from the repo root so
// results land in loadtest/results/.

import http from 'k6/http';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';
import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

export function env(name, fallback) {
  const value = __ENV[name];
  if (value === undefined || value === '') {
    if (fallback === undefined) {
      throw new Error(`set ${name} (see the runbook for this test)`);
    }
    return fallback;
  }
  return value;
}

export function envInt(name, fallback) {
  return parseInt(env(name, fallback === undefined ? undefined : String(fallback)), 10);
}

export const BASE_URL = env('BASE_URL').replace(/\/$/, '');

// Every status the API is designed to return is "expected": a 409 or 429 is
// an answer, not a failure. Only 5xx and surprises count in http_req_failed.
const expected = http.expectedStatuses(200, 201, 404, 409, 422, 429);

export function newKey() {
  return uuidv4().replace(/-/g, '');
}

export function reserveRequest(saleId, qty, key) {
  return {
    method: 'POST',
    url: `${BASE_URL}/sales/${saleId}/reserve`,
    body: JSON.stringify({ qty }),
    params: {
      headers: { 'Content-Type': 'application/json', 'Idempotency-Key': key },
      tags: { name: 'reserve' },
      responseCallback: expected,
    },
  };
}

export function reserve(saleId, qty, key) {
  const r = reserveRequest(saleId, qty, key);
  return http.post(r.url, r.body, r.params);
}

export function confirm(holdId) {
  return http.post(`${BASE_URL}/holds/${holdId}/confirm`, null, {
    tags: { name: 'confirm' },
    responseCallback: expected,
  });
}

export function getSale(saleId) {
  const res = http.get(`${BASE_URL}/sales/${saleId}`, { tags: { name: 'get_sale' }, responseCallback: expected });
  return res.status === 200 ? res.json() : null;
}

export function retryAfterSeconds(res) {
  const value = parseFloat(res.headers['Retry-After'] || res.headers['retry-after'] || '1');
  return Number.isFinite(value) ? value : 1;
}

// Counter value from the end-of-test summary (0 if the metric never fired).
export function count(data, metric) {
  const m = data.metrics[metric];
  return m ? m.values.count : 0;
}

export function gauge(data, metric) {
  const m = data.metrics[metric];
  return m ? m.values.value : null;
}

// Writes loadtest/results/<test>-<UTC timestamp>.json and prints the usual
// k6 summary. `verdict` is the test's own pass/fail reading of the numbers.
export function writeResults(test, data, params, verdict) {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const dir = env('RESULTS_DIR', 'loadtest/results');
  const result = {
    test,
    finished_at: new Date().toISOString(),
    base_url: BASE_URL,
    params,
    verdict,
    metrics: data.metrics,
  };
  return {
    stdout: `${textSummary(data, { indent: ' ', enableColors: false })}\n\n${test} verdict: ${JSON.stringify(verdict, null, 2)}\n`,
    [`${dir}/${test}-${stamp}.json`]: JSON.stringify(result, null, 2),
  };
}
