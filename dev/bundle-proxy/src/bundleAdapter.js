// bundleAdapter.js — eth_sendRawTransaction → op-rbuilder 直接转发
//
// ⚠️ 设计演进（2026-05 实测）：
// 之前的设计是包成 eth_sendBundle 发给 op-rbuilder（按 Flashbots Bundle V1 spec），
// 但 op-rbuilder 0.3.x（reth-builder fork）**不再暴露 eth_sendBundle / mev_sendBundle
// 任何 bundle RPC**：
//
//   curl op-rbuilder:9550 eth_sendBundle       → -32601 Method not found
//   curl op-rbuilder:9550 mev_sendBundle       → -32601 Method not found
//   curl op-rbuilder:9550 flashbots_sendBundle → -32601 Method not found
//
// 新版 op-rbuilder 的接入模型：dApp 把 raw tx 直接发到 op-rbuilder 的 HTTP RPC
// （--http.api=eth 默认开了 eth_sendRawTransaction），op-rbuilder 把 tx 放进
// 自己的 internal mempool，然后用这个 mempool 建 builder payload，由
// rollup-boost 在 engine_getPayload 时选用。
//
// 所以 bundle-proxy 的"适配"实际只剩三件事：
//   1. 把 dApp 的 eth_sendRawTransaction 直接 forward 给 op-rbuilder
//   2. 失败时 fallback 到 op-geth（v6 行为）
//   3. 入口做 in-flight 限流 / 熔断 / metrics / chainId 拦截

import { keccak256 } from 'viem';
import { callUpstream, UpstreamError } from './upstream.js';
import { getHead } from './headTracker.js';
import { config } from './config.js';

export function computeTxHash(rawTxHex) {
  if (typeof rawTxHex !== 'string' || !rawTxHex.startsWith('0x')) {
    throw new Error('invalid rawTx: expected 0x-prefixed hex string');
  }
  return keccak256(rawTxHex);
}

/**
 * 把 raw tx 直接转发给 op-rbuilder 的 eth_sendRawTransaction。
 * 函数名保留 sendRawAsBundle 是历史兼容（避免改其他文件），实际不再包 bundle。
 *
 * @param {string} rawTxHex 0x-prefixed signed raw tx
 * @returns {Promise<string>} tx hash（优先用上游返回的；若上游没返回则用本地 keccak256）
 */
export async function sendRawAsBundle(rawTxHex) {
  // head 不再是必需的（不再算 blockNumber），但还是做基本健康检查 —
  // 0 表示 bundle-proxy 自身的 head tracker 没起来，链可能还在 init。
  const head = getHead();
  if (head === 0) {
    throw new BundleAdapterError('HEAD_NOT_READY', 'L2 head not yet fetched, retry shortly');
  }

  // 直接 forward 给 op-rbuilder。op-rbuilder 内部走自己的 mempool/builder 流程，
  // 进了 builder payload 之后 rollup-boost 在 getPayload 时 prefer builder block。
  // 失败 → 抛 UpstreamError，上层决定 fail-fast / fallback 到 op-geth。
  const { result } = await callUpstream('rbuilder', 'eth_sendRawTransaction', [rawTxHex]);

  // 通常 result 就是 op-rbuilder 验证签名后返回的 tx hash；防御性兜底用本地 keccak256。
  return result || computeTxHash(rawTxHex);
}

/**
 * Fallback：op-rbuilder 不可用时，直接走 op-geth eth_sendRawTransaction（v6 baseline 行为）。
 * @param {string} rawTxHex
 * @returns {Promise<string>} tx hash
 */
export async function sendRawAsLegacy(rawTxHex) {
  const { result } = await callUpstream('opgeth', 'eth_sendRawTransaction', [rawTxHex]);
  return result;
}

export class BundleAdapterError extends Error {
  constructor(kind, message) {
    super(message);
    this.name = 'BundleAdapterError';
    this.kind = kind;
  }
}
