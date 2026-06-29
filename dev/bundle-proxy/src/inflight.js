// inflight.js — fail-fast 计数器
//
// 设计：单一全局 in-flight 计数。任何 method 进入时 +1，离开时 -1。
// 超过 IN_FLIGHT_LIMIT 立刻拒绝（不入队、不重试）。
//
// 这是 mychain Phase 2 的核心设计。op-rbuilder 自身在过载时会把请求 hold 30+ 秒
// 而不是返错（Phase 1.5 实测），生产环境会演变成雪崩。bundle-proxy 在入口提前
// 拒绝，让客户端立刻知道而不是 hang 30s。

import { config } from './config.js';

let inflight = 0;
let totalAccepted = 0;
let totalRejected = 0;

export function acquire() {
  if (inflight >= config.IN_FLIGHT_LIMIT) {
    totalRejected++;
    return false;
  }
  inflight++;
  totalAccepted++;
  return true;
}

export function release() {
  if (inflight > 0) inflight--;
}

export function snapshot() {
  return {
    inflight,
    limit: config.IN_FLIGHT_LIMIT,
    totalAccepted,
    totalRejected,
    saturation: inflight / config.IN_FLIGHT_LIMIT,
  };
}

// 测试用
export function _reset() {
  inflight = 0;
  totalAccepted = 0;
  totalRejected = 0;
}
