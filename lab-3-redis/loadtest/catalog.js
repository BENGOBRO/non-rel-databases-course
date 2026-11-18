// Нагрузка на каталог: чтение карточек (популярные товары запрашиваются чаще),
// топ категорий, изменение цены/остатка и запросы несуществующих товаров.
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://app:8000';
const TARGET = Number(__ENV.TARGET_RPS || 1000);
const HOLD = __ENV.HOLD || '2m';
const PRODUCTS = 50000;
const CATEGORIES = 40;

const cacheCounters = {
  hit: new Counter('cache_hit'),
  miss: new Counter('cache_miss'),
  bypass: new Counter('cache_bypass'),
};

export const options = {
  discardResponseBodies: true,
  dns: { ttl: '1m', select: 'roundRobin', policy: 'preferIPv4' },
  scenarios: {
    catalog: {
      executor: 'ramping-arrival-rate',
      startRate: 50,
      timeUnit: '1s',
      preAllocatedVUs: 200,
      maxVUs: 2000,
      stages: [
        { target: Math.round(TARGET / 4), duration: '30s' },
        { target: TARGET, duration: '2m' },
        { target: TARGET, duration: HOLD },
        { target: 0, duration: '20s' },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{name:product}': ['p(95)<100'],
    'http_req_duration{name:category_top}': ['p(95)<250'],
    'http_req_duration{name:update}': ['p(95)<250'],
    'http_req_duration{name:missing}': ['p(95)<100'],
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

// Распределение со смещением к началу диапазона: ~30 % запросов приходится
// на 1 % товаров, ~55 % — на 10 %.
function popularProduct() {
  return Math.floor(PRODUCTS * Math.pow(Math.random(), 4)) + 1;
}

function record(res) {
  const counter = cacheCounters[(res.headers['X-Cache'] || '').toLowerCase()];
  if (counter) counter.add(1);
}

export default function () {
  const r = Math.random();
  let res;
  if (r < 0.85) {
    res = http.get(`${BASE}/products/${popularProduct()}`, { tags: { name: 'product' } });
    check(res, { 'product 200': (x) => x.status === 200 });
  } else if (r < 0.95) {
    const id = 1 + Math.floor(Math.random() * CATEGORIES);
    res = http.get(`${BASE}/categories/${id}/top`, { tags: { name: 'category_top' } });
    check(res, { 'category 200': (x) => x.status === 200 });
  } else if (r < 0.99) {
    const body = JSON.stringify({ stock: Math.floor(Math.random() * 500) });
    res = http.patch(`${BASE}/products/${popularProduct()}`, body, {
      headers: { 'Content-Type': 'application/json' },
      tags: { name: 'update' },
    });
    check(res, { 'update 200': (x) => x.status === 200 });
  } else {
    const id = PRODUCTS + 1 + Math.floor(Math.random() * 1000);
    res = http.get(`${BASE}/products/${id}`, {
      tags: { name: 'missing' },
      responseCallback: http.expectedStatuses(404),
    });
    check(res, { 'missing 404': (x) => x.status === 404 });
  }
  record(res);
}

export function handleSummary(data) {
  const out = __ENV.SUMMARY ? { [`/results/${__ENV.SUMMARY}.json`]: JSON.stringify(data, null, 2) } : {};
  return { stdout: textSummary(data), ...out };
}

function textSummary(data) {
  const m = data.metrics;
  const fmt = (v) => (v === undefined ? '-' : v.toFixed(2));
  const lines = [];
  const reqs = m.http_reqs.values;
  lines.push(`requests: ${reqs.count}  rate: ${fmt(reqs.rate)}/s  failed: ${(m.http_req_failed.values.rate * 100).toFixed(2)}%`);
  for (const name of ['product', 'category_top', 'update', 'missing']) {
    const t = m[`http_req_duration{name:${name}}`];
    if (!t) continue;
    const v = t.values;
    lines.push(`${name.padEnd(13)} avg ${fmt(v.avg)} ms  p50 ${fmt(v['p(50)'])}  p95 ${fmt(v['p(95)'])}  p99 ${fmt(v['p(99)'])}  max ${fmt(v.max)}`);
  }
  const count = (k) => (m[k] ? m[k].values.count : 0);
  const hit = count('cache_hit'), miss = count('cache_miss'), bypass = count('cache_bypass');
  const ratio = hit + miss ? ((hit / (hit + miss)) * 100).toFixed(1) : '-';
  lines.push(`cache: hit ${hit}  miss ${miss}  bypass ${bypass}  hit ratio ${ratio}%`);
  lines.push(`dropped_iterations: ${count('dropped_iterations')}  max VUs: ${m.vus_max.values.max}`);
  for (const [k, t] of Object.entries(data.metrics)) {
    if (t.thresholds) {
      for (const [expr, res] of Object.entries(t.thresholds)) {
        lines.push(`threshold ${k} ${expr}: ${res.ok ? 'ok' : 'FAILED'}`);
      }
    }
  }
  return lines.join('\n') + '\n';
}
