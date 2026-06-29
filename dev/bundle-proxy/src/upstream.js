// upstream.js — 三个 undici keep-alive 池，按上游分别管理连接。
//
// 为什么三个池不共用：
//   - op-rbuilder（写）流量大，要 32×10 高 pipelining
//   - op-geth（读 / fallback）流量小，4×4 够用
//   - flashblocks-rpc（读）流量中，8×4
// 共用一个池会让大流量挤掉读 RPC 的连接，导致读 RPC 排队。

import { Agent, request } from 'undici';
import { config } from './config.js';

function makeAgent({ connections, pipelining }) {
  return new Agent({
    connections,
    pipelining,
    keepAliveTimeout: 60_000,
    keepAliveMaxTimeout: 120_000,
    bodyTimeout: config.HTTP_TIMEOUT_MS,
    headersTimeout: config.HTTP_TIMEOUT_MS,
  });
}

const agents = {
  rbuilder:    makeAgent({ connections: config.HTTP_POOL_SIZE, pipelining: config.HTTP_PIPELINE }),
  opgeth:      makeAgent({ connections: 4, pipelining: 4 }),
  flashblocks: makeAgent({ connections: 8, pipelining: 4 }),
};

const urls = {
  rbuilder:    config.RBUILDER_URL,
  opgeth:      config.OPGETH_URL,
  flashblocks: config.FLASHBLOCKS_RPC_URL,
};

/**
 * 调上游 JSON-RPC 节点。
 * @param {'rbuilder'|'opgeth'|'flashblocks'} target 池名
 * @param {string} method JSON-RPC method
 * @param {any[]} params
 * @returns {Promise<any>} JSON-RPC result
 * @throws {UpstreamError} HTTP 非 2xx / JSON 解析失败 / JSON-RPC error
 */
export async function callUpstream(target, method, params) {
  const url = urls[target];
  const agent = agents[target];
  if (!url || !agent) throw new UpstreamError('CONFIG', `unknown target ${target}`);

  const t0 = Date.now();
  let res;
  try {
    res = await request(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', method, params, id: 1 }),
      dispatcher: agent,
      bodyTimeout: config.HTTP_TIMEOUT_MS,
      headersTimeout: config.HTTP_TIMEOUT_MS,
    });
  } catch (e) {
    throw new UpstreamError('NETWORK', `${target}.${method}: ${e.message}`, { latencyMs: Date.now() - t0 });
  }

  const latencyMs = Date.now() - t0;
  const text = await res.body.text();

  if (res.statusCode < 200 || res.statusCode >= 300) {
    // op-rbuilder 在过载时返回 plain text "Too many connections"，
    // 这里把 HTTP 错误透出，让调用方决定 fallback / fail-fast。
    throw new UpstreamError('HTTP', `${target}.${method}: ${res.statusCode} ${text.slice(0, 200)}`, {
      latencyMs, status: res.statusCode,
    });
  }

  let body;
  try {
    body = JSON.parse(text);
  } catch (e) {
    throw new UpstreamError('PARSE', `${target}.${method}: invalid JSON: ${text.slice(0, 200)}`, { latencyMs });
  }

  if (body.error) {
    throw new UpstreamError('JSONRPC', `${target}.${method}: ${body.error.code} ${body.error.message}`, {
      latencyMs, jsonrpcError: body.error,
    });
  }

  return { result: body.result, latencyMs };
}

export class UpstreamError extends Error {
  constructor(kind, message, meta = {}) {
    super(message);
    this.name = 'UpstreamError';
    this.kind = kind;
    this.meta = meta;
  }
}

export async function destroyAgents() {
  await Promise.all(Object.values(agents).map((a) => a.close().catch(() => {})));
}
