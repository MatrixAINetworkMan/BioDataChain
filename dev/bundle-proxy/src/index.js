// index.js — fastify 入口
//
// 端口：
//   PORT=9560          客户端 JSON-RPC 入口（POST /, GET /healthz, GET /status）
//   METRICS_PORT=9561  Prometheus scrape（GET /metrics）
//
// 优雅退出：SIGTERM/SIGINT 后等 5s 让 in-flight 请求完成，然后 force exit。

import Fastify from 'fastify';
import { config, dumpConfig } from './config.js';
import { handleRpc, statusSnapshot } from './rpcRouter.js';
import { startTracker, stopTracker, snapshot as headSnapshot } from './headTracker.js';
import { destroyAgents } from './upstream.js';
import { snapshot as inflightSnapshot } from './inflight.js';
import { snapshot as circuitSnapshot } from './circuit.js';
import {
  registry,
  inflightLimit,
  inflightGauge,
  circuitState,
  headStaleMs,
} from './metrics.js';

// =============================================================================
// 主 RPC server (fastify)
// =============================================================================
export async function buildRpcServer() {
  const app = Fastify({
    logger: { level: config.LOG_LEVEL },
    bodyLimit: 1024 * 1024,           // 1MB JSON-RPC body 限制（raw tx 通常 < 5KB）
    disableRequestLogging: true,      // 高 TPS 下日志会爆，只保留错误日志
  });

  app.get('/healthz', async () => {
    const head = headSnapshot();
    if (head.head === 0) {
      return { status: 'starting', reason: 'head_not_yet_fetched' };
    }
    return { status: 'ok', head: head.head, staleMs: head.staleMs };
  });

  app.get('/status', async () => statusSnapshot());

  app.post('/', async (req, reply) => {
    const body = req.body;
    if (Array.isArray(body)) {
      const results = await Promise.all(body.map((r) => handleRpc(r)));
      return reply.send(results);
    }
    if (typeof body !== 'object' || body === null) {
      return reply.code(400).send({
        jsonrpc: '2.0',
        id: null,
        error: { code: -32600, message: 'Invalid request' },
      });
    }
    const result = await handleRpc(body);
    return reply.send(result);
  });

  app.setErrorHandler((err, req, reply) => {
    app.log.error({ err, method: req.method, url: req.url }, 'fastify error');
    reply.code(500).send({
      jsonrpc: '2.0',
      id: null,
      error: { code: -32603, message: 'Internal error', data: err.message },
    });
  });

  return app;
}

// =============================================================================
// Metrics server（独立端口）
// =============================================================================
export async function buildMetricsServer() {
  const app = Fastify({ logger: false });

  app.get('/metrics', async (req, reply) => {
    const inflight = inflightSnapshot();
    inflightGauge.set(inflight.inflight);
    inflightLimit.set(inflight.limit);

    const circuit = circuitSnapshot();
    circuitState.set(
      circuit.state === 'closed' ? 0 : circuit.state === 'half_open' ? 1 : 2,
    );

    const head = headSnapshot();
    headStaleMs.set(head.staleMs);

    reply.header('content-type', registry.contentType);
    return registry.metrics();
  });

  return app;
}

// =============================================================================
// 启动 + 优雅退出
// =============================================================================
export async function start() {
  console.log('[bundle-proxy] config:\n' + dumpConfig());

  startTracker();

  const rpc = await buildRpcServer();
  const metrics = await buildMetricsServer();

  await rpc.listen({ host: config.HOST, port: config.PORT });
  await metrics.listen({ host: config.HOST, port: config.METRICS_PORT });

  console.log(`[bundle-proxy] RPC     listening on http://${config.HOST}:${config.PORT}`);
  console.log(`[bundle-proxy] Metrics listening on http://${config.HOST}:${config.METRICS_PORT}/metrics`);

  const shutdown = async (sig) => {
    console.log(`[bundle-proxy] ${sig} received, draining...`);
    stopTracker();
    await Promise.race([
      Promise.all([rpc.close(), metrics.close()]),
      new Promise((r) => setTimeout(r, 5000)),
    ]);
    await destroyAgents();
    console.log('[bundle-proxy] bye');
    process.exit(0);
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT',  () => shutdown('SIGINT'));
}

const isMain = import.meta.url === `file://${process.argv[1]}` ||
               process.argv[1]?.endsWith('/src/index.js');
if (isMain) {
  start().catch((e) => {
    console.error('[bundle-proxy] startup failed:', e);
    process.exit(1);
  });
}
