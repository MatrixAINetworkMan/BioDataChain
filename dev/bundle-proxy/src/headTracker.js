// headTracker.js — 缓存 L2 head block number
//
// 为什么需要：每个 eth_sendBundle 的 blockNumber 字段需要"head + N"。
// 若每笔都查 head，800 TPS = 800 次额外 eth_blockNumber，浪费带宽。
// 后台 ticker 每 HEAD_REFRESH_MS（默认 200ms）查一次，业务方调用零延迟读取缓存。
//
// 1s block_time 下，head 每秒变 1。200ms refresh = 偶尔会用到上一个 block 的 head。
// 这没问题：bundle.blockNumber 给"head + 10"已经留了 10s 容错窗口（详见 config.js
// 的 BUNDLE_BLOCK_OFS 注释，Phase 1.6 实测决定）。

import { callUpstream, UpstreamError } from './upstream.js';
import { config } from './config.js';

let head = 0;
let lastRefreshAt = 0;
let lastError = null;
let refreshTimer = null;

export async function refreshHead() {
  try {
    // 优先从 op-geth 读 head（finalized，最准）；rbuilder 也能读但 pre-confirm 偶尔领先
    const { result } = await callUpstream('opgeth', 'eth_blockNumber', []);
    head = parseInt(result, 16);
    lastRefreshAt = Date.now();
    lastError = null;
    return head;
  } catch (e) {
    lastError = e instanceof UpstreamError ? `${e.kind}: ${e.message}` : e.message;
    // 不抛：让 startTracker 继续后台重试，业务方读取上次缓存的 head（哪怕过期）
    return head;
  }
}

export function startTracker() {
  if (refreshTimer) return;
  refreshHead();
  refreshTimer = setInterval(refreshHead, config.HEAD_REFRESH_MS);
  refreshTimer.unref();
}

export function stopTracker() {
  if (refreshTimer) {
    clearInterval(refreshTimer);
    refreshTimer = null;
  }
}

export function getHead() {
  return head;
}

export function snapshot() {
  return {
    head,
    lastRefreshAt,
    staleMs: Date.now() - lastRefreshAt,
    lastError,
  };
}

export function _setHeadForTest(n) {
  head = n;
  lastRefreshAt = Date.now();
}
