// circuit.js — 半开熔断器（针对 op-rbuilder fallback）
//
// 状态机：
//   CLOSED   连续 N 次失败 → OPEN
//   OPEN     所有请求直接走 fallback（op-geth），不打 rbuilder
//   HALF     OPEN 持续 FALLBACK_HALF_OPEN_MS 后切到 HALF，
//            放 1 笔试探请求；通过则 → CLOSED，不通过则 → OPEN
//
// 不引第三方库（avoid opossum 依赖膨胀），手写 100 行内。

import { config } from './config.js';

const STATE = { CLOSED: 'closed', OPEN: 'open', HALF_OPEN: 'half_open' };

let state = STATE.CLOSED;
let consecutiveFailures = 0;
let openedAt = 0;
let probing = false;

let totalSuccess = 0;
let totalFailure = 0;
let totalShortCircuit = 0;

export function shouldFallback() {
  if (!config.ENABLE_FALLBACK) return false;
  if (state === STATE.OPEN) {
    if (Date.now() - openedAt > config.FALLBACK_HALF_OPEN_MS) {
      state = STATE.HALF_OPEN;
      probing = false;
    } else {
      totalShortCircuit++;
      return true;
    }
  }
  if (state === STATE.HALF_OPEN && probing) {
    totalShortCircuit++;
    return true;
  }
  if (state === STATE.HALF_OPEN) {
    probing = true;
  }
  return false;
}

export function reportSuccess() {
  totalSuccess++;
  consecutiveFailures = 0;
  if (state === STATE.HALF_OPEN) {
    state = STATE.CLOSED;
    probing = false;
  }
}

export function reportFailure() {
  totalFailure++;
  consecutiveFailures++;
  if (state === STATE.HALF_OPEN) {
    state = STATE.OPEN;
    openedAt = Date.now();
    probing = false;
    return;
  }
  if (consecutiveFailures >= config.FALLBACK_THRESHOLD) {
    state = STATE.OPEN;
    openedAt = Date.now();
  }
}

export function snapshot() {
  return {
    state,
    consecutiveFailures,
    openedAt,
    totalSuccess,
    totalFailure,
    totalShortCircuit,
  };
}

export function _reset() {
  state = STATE.CLOSED;
  consecutiveFailures = 0;
  openedAt = 0;
  probing = false;
  totalSuccess = 0;
  totalFailure = 0;
  totalShortCircuit = 0;
}
