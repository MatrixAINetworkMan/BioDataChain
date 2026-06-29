// rpcRouter.js — JSON-RPC method 分发
//
// 三类 method：
//   1. 写：eth_sendRawTransaction → bundleAdapter.sendRawAsBundle（带 fail-fast + fallback）
//   2. 读：eth_call / eth_getBalance / eth_getTransactionByHash 等 → 透传 flashblocks-rpc 或 op-geth
//   3. 元数据：eth_chainId / net_version → 本地缓存返回（startup 时 fetch 一次）
//
// 不支持的 method 直接透传 op-geth（默认行为），让客户端能用所有现有 SDK。

import { callUpstream, UpstreamError } from './upstream.js';
import { sendRawAsBundle, sendRawAsLegacy, BundleAdapterError } from './bundleAdapter.js';
import { acquire, release } from './inflight.js';
import { shouldFallback, reportSuccess, reportFailure } from './circuit.js';
import { config } from './config.js';
import {
  rpcTotal,
  rpcLatency,
  upstreamLatency,
  inflightGauge,
  fallbackUsed,
} from './metrics.js';
import { snapshot as headSnapshot } from './headTracker.js';
import { snapshot as inflightSnapshot } from './inflight.js';
import { snapshot as circuitSnapshot } from './circuit.js';

// JSON-RPC 错误码（参考 EIP-1474 + Flashbots 约定）
const RPC_ERRORS = {
  PARSE_ERROR:        { code: -32700, message: 'Parse error' },
  INVALID_REQUEST:    { code: -32600, message: 'Invalid request' },
  METHOD_NOT_FOUND:   { code: -32601, message: 'Method not found' },
  INVALID_PARAMS:     { code: -32602, message: 'Invalid params' },
  INTERNAL_ERROR:     { code: -32603, message: 'Internal error' },
  SERVER_OVERLOADED:  { code: -32000, message: 'Server overloaded (in-flight limit reached)' },
  HEAD_NOT_READY:     { code: -32001, message: 'Upstream head not ready, retry shortly' },
  UPSTREAM_FAILED:    { code: -32002, message: 'Upstream failed (no fallback or fallback also failed)' },
};

const READ_METHODS_FLASHBLOCKS = new Set([
  // 优先 flashblocks-rpc（pre-confirmation 视图，业务前端要"快"反馈）
  'eth_getTransactionByHash',
  'eth_getTransactionReceipt',
  'eth_getBalance',
  'eth_getCode',
  'eth_getStorageAt',
  'eth_getTransactionCount',
  'eth_blockNumber',
  'eth_call',
  'eth_estimateGas',
  'eth_gasPrice',
  'eth_maxPriorityFeePerGas',
  'eth_feeHistory',
]);

const READ_METHODS_OPGETH = new Set([
  // finalized 视图必须走 op-geth：trace、historical block、receipt 走 indexer 等
  'debug_traceTransaction',
  'debug_traceCall',
  'debug_traceBlockByNumber',
  'debug_traceBlockByHash',
  'eth_getBlockByNumber',
  'eth_getBlockByHash',
  'eth_getBlockReceipts',
  'eth_getLogs',
]);

const META_METHODS = new Set([
  'eth_chainId',
  'net_version',
  'web3_clientVersion',
]);

// =============================================================================
// 入口：处理一个 JSON-RPC 请求体（已 parse 成对象）
// =============================================================================
export async function handleRpc(req, ctx) {
  const t0 = Date.now();
  const id = req?.id ?? null;
  const method = req?.method;

  if (!method || typeof method !== 'string') {
    return errorResp(id, RPC_ERRORS.INVALID_REQUEST, t0, 'unknown');
  }

  // ============= 写：eth_sendRawTransaction =============
  if (method === 'eth_sendRawTransaction') {
    return await handleSendRawTransaction(id, req.params || [], t0, ctx);
  }

  // ============= 元数据：缓存返回 =============
  if (method === 'eth_chainId') {
    rpcTotal.inc({ method, outcome: 'ok' });
    rpcLatency.observe({ method, outcome: 'ok' }, Date.now() - t0);
    return { jsonrpc: '2.0', id, result: '0x' + config.CHAIN_ID.toString(16) };
  }

  // ============= 读：透传 =============
  let target;
  if (READ_METHODS_FLASHBLOCKS.has(method)) {
    target = config.READ_TARGET === 'opgeth' ? 'opgeth' : 'flashblocks';
  } else if (READ_METHODS_OPGETH.has(method)) {
    target = 'opgeth';
  } else if (META_METHODS.has(method)) {
    target = 'opgeth';
  } else {
    // 未知 method 默认透 op-geth（SDK 兼容兜底）
    target = 'opgeth';
  }

  return await handleReadPassthrough(id, method, req.params || [], target, t0);
}

// =============================================================================
// 写路径：fail-fast + bundle adapter + fallback
// =============================================================================
async function handleSendRawTransaction(id, params, t0, ctx) {
  const method = 'eth_sendRawTransaction';

  if (!Array.isArray(params) || params.length < 1 || typeof params[0] !== 'string') {
    rpcTotal.inc({ method, outcome: 'invalid_params' });
    return errorResp(id, RPC_ERRORS.INVALID_PARAMS, t0, method);
  }
  const rawTx = params[0];

  // Step 1：fail-fast
  if (!acquire()) {
    rpcTotal.inc({ method, outcome: 'rejected' });
    rpcLatency.observe({ method, outcome: 'rejected' }, Date.now() - t0);
    return errorResp(id, RPC_ERRORS.SERVER_OVERLOADED, t0, method);
  }
  inflightGauge.set(inflightSnapshot().inflight);

  try {
    // Step 2：检查熔断器，OPEN 时直接走 fallback
    if (shouldFallback()) {
      try {
        const txHash = await sendRawAsLegacy(rawTx);
        fallbackUsed.inc();
        rpcTotal.inc({ method, outcome: 'fallback_ok' });
        rpcLatency.observe({ method, outcome: 'fallback_ok' }, Date.now() - t0);
        return { jsonrpc: '2.0', id, result: txHash };
      } catch (e) {
        rpcTotal.inc({ method, outcome: 'fallback_failed' });
        rpcLatency.observe({ method, outcome: 'fallback_failed' }, Date.now() - t0);
        return errorResp(id, {
          ...RPC_ERRORS.UPSTREAM_FAILED,
          data: e instanceof UpstreamError ? `${e.kind}: ${e.message}` : e.message,
        }, t0, method);
      }
    }

    // Step 3：走 op-rbuilder 主路径
    try {
      const txHash = await sendRawAsBundle(rawTx);
      reportSuccess();
      rpcTotal.inc({ method, outcome: 'ok' });
      rpcLatency.observe({ method, outcome: 'ok' }, Date.now() - t0);
      return { jsonrpc: '2.0', id, result: txHash };
    } catch (e) {
      reportFailure();

      if (e instanceof BundleAdapterError && e.kind === 'HEAD_NOT_READY') {
        rpcTotal.inc({ method, outcome: 'head_not_ready' });
        rpcLatency.observe({ method, outcome: 'head_not_ready' }, Date.now() - t0);
        return errorResp(id, RPC_ERRORS.HEAD_NOT_READY, t0, method);
      }

      // op-rbuilder 失败 → 立即试 fallback（不等熔断器开），让本笔尽量成功
      if (config.ENABLE_FALLBACK) {
        try {
          const txHash = await sendRawAsLegacy(rawTx);
          fallbackUsed.inc();
          rpcTotal.inc({ method, outcome: 'rbuilder_fail_fallback_ok' });
          rpcLatency.observe({ method, outcome: 'rbuilder_fail_fallback_ok' }, Date.now() - t0);
          return { jsonrpc: '2.0', id, result: txHash };
        } catch (fbErr) {
          rpcTotal.inc({ method, outcome: 'both_failed' });
          rpcLatency.observe({ method, outcome: 'both_failed' }, Date.now() - t0);
          return errorResp(id, {
            ...RPC_ERRORS.UPSTREAM_FAILED,
            data: `rbuilder: ${e.message} | fallback: ${fbErr.message}`,
          }, t0, method);
        }
      }

      rpcTotal.inc({ method, outcome: 'rbuilder_failed' });
      rpcLatency.observe({ method, outcome: 'rbuilder_failed' }, Date.now() - t0);
      return errorResp(id, {
        ...RPC_ERRORS.UPSTREAM_FAILED,
        data: e instanceof UpstreamError ? `${e.kind}: ${e.message}` : e.message,
      }, t0, method);
    }
  } finally {
    release();
    inflightGauge.set(inflightSnapshot().inflight);
  }
}

// =============================================================================
// 读路径：透传，带 metrics
// =============================================================================
async function handleReadPassthrough(id, method, params, target, t0) {
  try {
    const { result, latencyMs } = await callUpstream(target, method, params);
    upstreamLatency.observe({ target, method, outcome: 'ok' }, latencyMs);
    rpcTotal.inc({ method, outcome: 'ok' });
    rpcLatency.observe({ method, outcome: 'ok' }, Date.now() - t0);
    return { jsonrpc: '2.0', id, result };
  } catch (e) {
    const outcome = e instanceof UpstreamError ? `upstream_${e.kind.toLowerCase()}` : 'error';
    upstreamLatency.observe({ target, method, outcome }, e?.meta?.latencyMs ?? Date.now() - t0);
    rpcTotal.inc({ method, outcome });
    rpcLatency.observe({ method, outcome }, Date.now() - t0);

    // JSON-RPC error 透出（保留 code/message/data）
    if (e instanceof UpstreamError && e.kind === 'JSONRPC') {
      return { jsonrpc: '2.0', id, error: e.meta.jsonrpcError };
    }
    return errorResp(id, {
      ...RPC_ERRORS.UPSTREAM_FAILED,
      data: e instanceof UpstreamError ? `${e.kind}: ${e.message}` : e.message,
    }, t0, method);
  }
}

function errorResp(id, err, t0, method) {
  // err 结构：{ code, message, data? }
  return { jsonrpc: '2.0', id, error: err };
}

// status snapshot for /status endpoint
export function statusSnapshot() {
  return {
    head: headSnapshot(),
    inflight: inflightSnapshot(),
    circuit: circuitSnapshot(),
    config: {
      bundleBlockOffset: config.BUNDLE_BLOCK_OFS,
      inflightLimit: config.IN_FLIGHT_LIMIT,
      enableFallback: config.ENABLE_FALLBACK,
      readTarget: config.READ_TARGET,
      chainId: config.CHAIN_ID,
    },
  };
}
