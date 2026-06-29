// metrics.js — Prometheus 指标
//
// 暴露在独立端口（METRICS_PORT，默认 9561）防止 dApp 流量挤掉 scrape 请求。

import { Registry, Counter, Histogram, Gauge, collectDefaultMetrics } from 'prom-client';

export const registry = new Registry();
collectDefaultMetrics({ register: registry, prefix: 'bundle_proxy_' });

export const rpcTotal = new Counter({
  name: 'bundle_proxy_rpc_total',
  help: 'Total RPC requests received from clients',
  labelNames: ['method', 'outcome'],
  registers: [registry],
});

export const rpcLatency = new Histogram({
  name: 'bundle_proxy_rpc_latency_ms',
  help: 'End-to-end client request latency (ms)',
  labelNames: ['method', 'outcome'],
  buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000],
  registers: [registry],
});

export const upstreamLatency = new Histogram({
  name: 'bundle_proxy_upstream_latency_ms',
  help: 'Upstream call latency (ms)',
  labelNames: ['target', 'method', 'outcome'],
  buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000],
  registers: [registry],
});

export const inflightGauge = new Gauge({
  name: 'bundle_proxy_inflight',
  help: 'Current in-flight requests',
  registers: [registry],
});

export const inflightLimit = new Gauge({
  name: 'bundle_proxy_inflight_limit',
  help: 'Configured in-flight limit',
  registers: [registry],
});

export const circuitState = new Gauge({
  name: 'bundle_proxy_circuit_state',
  help: 'Circuit breaker state (0=closed, 1=half_open, 2=open)',
  registers: [registry],
});

export const fallbackUsed = new Counter({
  name: 'bundle_proxy_fallback_total',
  help: 'Number of requests that fell back to op-geth',
  registers: [registry],
});

export const headStaleMs = new Gauge({
  name: 'bundle_proxy_head_stale_ms',
  help: 'Milliseconds since last successful head refresh',
  registers: [registry],
});
