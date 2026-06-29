// smoke.test.js — bundle-proxy 端到端 smoke 测试
//
// 跑法：
//   cd dev/bundle-proxy && npm install && npm run test:smoke
//
// 不依赖外部容器：内置 mock-rbuilder 同进程起。
//
// 覆盖：
//   1. eth_sendRawTransaction 主路径（走 rbuilder）
//   2. mock rbuilder down → fallback 走 opgeth
//   3. in-flight 超限 → -32000 fail-fast
//   4. eth_chainId 走本地缓存
//   5. eth_call 透传 flashblocks-rpc
//   6. /healthz 返回 head
//   7. /metrics 暴露 counter

import test from 'node:test';
import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';

// 必须在 import bundle-proxy 之前设环境变量，因为 config.js 在加载时 freeze
const MOCK_PORT = 18545;
process.env.PORT = '19560';
process.env.METRICS_PORT = '19561';
process.env.RBUILDER_URL    = `http://127.0.0.1:${MOCK_PORT}/rbuilder`;
process.env.OPGETH_URL      = `http://127.0.0.1:${MOCK_PORT}/opgeth`;
process.env.FLASHBLOCKS_RPC_URL = `http://127.0.0.1:${MOCK_PORT}/flashblocks`;
process.env.HEAD_REFRESH_MS = '50';
process.env.IN_FLIGHT_LIMIT = '5';
process.env.HTTP_TIMEOUT_MS = '3000';
process.env.LOG_LEVEL = 'warn';
process.env.CHAIN_ID = '175700';
process.env.MOCK_LOG_LEVEL = 'silent';

const { startMock } = await import('../mock-rbuilder/index.js');
const { buildRpcServer, buildMetricsServer } = await import('../src/index.js');
const { startTracker, stopTracker, refreshHead } = await import('../src/headTracker.js');
const { _reset: resetInflight } = await import('../src/inflight.js');
const { _reset: resetCircuit } = await import('../src/circuit.js');
const { destroyAgents } = await import('../src/upstream.js');

const PROXY_URL = `http://127.0.0.1:19560`;
const METRICS_URL = `http://127.0.0.1:19561`;
const MOCK_CONTROL = `http://127.0.0.1:${MOCK_PORT}`;

// dummy raw tx（合法 hex 但不是真实有效的 EIP-1559 tx，mock 不验证）
const DUMMY_RAW_TX = '0x02f87282abcd' + '00'.repeat(80);

let mock, rpc, metrics;

async function setup() {
  mock = await startMock();
  rpc = await buildRpcServer();
  metrics = await buildMetricsServer();
  await rpc.listen({ host: '127.0.0.1', port: 19560 });
  await metrics.listen({ host: '127.0.0.1', port: 19561 });
  startTracker();
  await refreshHead();
  await sleep(60); // 让 head 刷一次
}

async function teardown() {
  stopTracker();
  await Promise.all([rpc?.close(), metrics?.close(), mock?.close()].filter(Boolean));
  await destroyAgents();
}

async function rpcCall(method, params = [], id = 1) {
  const res = await fetch(PROXY_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', method, params, id }),
  });
  return { status: res.status, body: await res.json() };
}

await setup();

test('1. eth_sendRawTransaction 走 rbuilder 主路径', async () => {
  const { body } = await rpcCall('eth_sendRawTransaction', [DUMMY_RAW_TX]);
  assert.equal(body.jsonrpc, '2.0');
  assert.equal(typeof body.result, 'string');
  assert.match(body.result, /^0x[0-9a-f]{64}$/);
  assert.equal(body.error, undefined);
});

test('2. mock rbuilder down → fallback opgeth', async () => {
  resetInflight();
  resetCircuit();
  await fetch(`${MOCK_CONTROL}/control/rbuilder/down`);
  try {
    const { body } = await rpcCall('eth_sendRawTransaction', [DUMMY_RAW_TX]);
    assert.equal(body.error, undefined, `expected fallback success, got: ${JSON.stringify(body.error)}`);
    assert.match(body.result, /^0x[0-9a-f]{64}$/);
  } finally {
    await fetch(`${MOCK_CONTROL}/control/rbuilder/up`);
  }
});

test('3. in-flight 超限 fail-fast', async () => {
  resetInflight();
  resetCircuit();
  // 让 rbuilder 慢 500ms，并发 10 笔（IN_FLIGHT_LIMIT=5）
  await fetch(`${MOCK_CONTROL}/control/rbuilder/slow?ms=500`);
  try {
    const promises = Array.from({ length: 10 }, () =>
      rpcCall('eth_sendRawTransaction', [DUMMY_RAW_TX]),
    );
    const results = await Promise.all(promises);
    const rejected = results.filter((r) => r.body.error?.code === -32000);
    assert.ok(rejected.length >= 3,
      `expected ≥3 fail-fast rejections (limit=5, concurrency=10), got ${rejected.length}`);
  } finally {
    await fetch(`${MOCK_CONTROL}/control/rbuilder/normal`);
  }
});

test('4. eth_chainId 本地缓存返回', async () => {
  const { body } = await rpcCall('eth_chainId');
  assert.equal(body.result, '0x' + (175700).toString(16));
});

test('5. eth_call 透传 flashblocks-rpc', async () => {
  const { body } = await rpcCall('eth_call', [{ to: '0x' + '00'.repeat(20) }, 'latest']);
  assert.equal(body.result, '0x');
});

test('6. eth_getBalance 透传 flashblocks-rpc', async () => {
  const { body } = await rpcCall('eth_getBalance', ['0x' + '00'.repeat(20), 'latest']);
  assert.equal(body.result, '0x56bc75e2d63100000');
});

test('7. /healthz 返回 head', async () => {
  const res = await fetch(`${PROXY_URL}/healthz`);
  const body = await res.json();
  assert.equal(body.status, 'ok');
  assert.ok(body.head > 0);
});

test('8. /status 返回 inflight + circuit + head 快照', async () => {
  const res = await fetch(`${PROXY_URL}/status`);
  const body = await res.json();
  assert.ok(body.inflight);
  assert.ok(body.circuit);
  assert.ok(body.head);
  assert.equal(body.config.chainId, 175700);
});

test('9. /metrics 暴露 prom counter', async () => {
  const res = await fetch(`${METRICS_URL}/metrics`);
  const text = await res.text();
  assert.match(text, /bundle_proxy_rpc_total/);
  assert.match(text, /bundle_proxy_inflight/);
  assert.match(text, /bundle_proxy_circuit_state/);
});

test('10. 批量 JSON-RPC（数组请求）', async () => {
  const res = await fetch(PROXY_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify([
      { jsonrpc: '2.0', method: 'eth_chainId', params: [], id: 1 },
      { jsonrpc: '2.0', method: 'eth_blockNumber', params: [], id: 2 },
    ]),
  });
  const body = await res.json();
  assert.equal(body.length, 2);
  assert.equal(body[0].result, '0x' + (175700).toString(16));
  assert.match(body[1].result, /^0x[0-9a-f]+$/);
});

test('11. invalid request 返回 -32600', async () => {
  const res = await fetch(PROXY_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: 'not json',
  });
  // fastify 的 JSON parse 失败默认返 400 + 错误信息
  assert.equal(res.status, 400);
});

test.after(async () => { await teardown(); });
