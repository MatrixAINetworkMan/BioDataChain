// flashblocks-spammer / spammer.js
//
// 通过 op-rbuilder 的 `eth_sendBundle` 发交易做 Flashblocks TPS 压测。
//
// 用法：
//   TARGET_TPS=200 N_SENDERS=50 DURATION_S=60 node spammer.js
//
// 关键设计：
//   1. 每秒 TARGET_TPS 笔 transfer，每笔单独 1 个 bundle（bundle 语义清晰，
//      builder 端独立判断 inclusion）。
//   2. N_SENDERS 个临时 EOA，funder 通过 1 个大 bundle 一次性给所有 sender
//      注资（绕过 P2P gossip 不可靠的问题）。
//   3. 实时统计：每秒打印 sent / ok / err / 链上 receipts。
//   4. 最终报告：链上实际 TPS（30-block 窗口）+ p50/p95 延迟。
//
// 详细文档见 README.md。

import { createPublicClient, http, parseEther, parseGwei, toHex, defineChain } from 'viem';
import { privateKeyToAccount, generatePrivateKey } from 'viem/accounts';
import { Agent, fetch as undiciFetch } from 'undici';

// ============= 配置（通过环境变量覆盖）=============
const RPC_URL          = process.env.RPC_URL          || 'http://127.0.0.1:8547';     // op-rbuilder eth_sendBundle 端点
const READ_RPC_URL     = process.env.READ_RPC_URL     || 'http://127.0.0.1:8548';     // flashblocks-rpc 用于读 head/balance
const FUNDER_KEY       = process.env.FUNDER_KEY       || '0x<FUNDER_PRIVATE_KEY>'; // 必须通过环境变量注入，勿入仓真实 key
const CHAIN_ID         = parseInt(process.env.CHAIN_ID         || '13');              // builder-playground default L2 chainId
const TARGET_TPS       = parseInt(process.env.TARGET_TPS       || '100');
const N_SENDERS        = parseInt(process.env.N_SENDERS        || '50');
const DURATION_S       = parseInt(process.env.DURATION_S       || '60');
const FUNDING_ETH      = process.env.FUNDING_ETH               || '1';                // 每个 sender 注资多少 ETH
const BUNDLE_BLOCK_OFS = parseInt(process.env.BUNDLE_BLOCK_OFS || '10');              // bundle.blockNumber = head + N。OFS=1 (next block) 在高 TPS 下 RPC 排队 ≥ 1s 时 bundle 已过期被 builder silent drop。OFS=10 给 10s 窗口，Phase 1.6 实测能把 inclusion 从 38% 提到 43%（仍非主因，但低成本必做）。
const GAS_PRICE_GWEI   = process.env.GAS_PRICE_GWEI            || '1';
const REPORT_INTERVAL_S= parseInt(process.env.REPORT_INTERVAL_S|| '5');
const ERR_SAMPLES_MAX  = parseInt(process.env.ERR_SAMPLES_MAX  || '5');               // 错误采样上限（诊断时调大）
const HTTP_POOL_SIZE   = parseInt(process.env.HTTP_POOL_SIZE   || '32');              // undici keep-alive pool size (复用 TCP 连接绕开 reth max-connections)
const HTTP_PIPELINE    = parseInt(process.env.HTTP_PIPELINE    || '10');              // 单连接上的 pipelined 请求数

// undici Agent：keep-alive + 复用 TCP，绕开 reth jsonrpsee 默认 max-connections=100 限制。
// 250 个 sender 并发请求 → 复用 32 个连接，每个连接最多 10 笔 pipeline，总并发 ~320，远低于 100 也能撑 1000 RPS。
const httpAgent = new Agent({
  connections: HTTP_POOL_SIZE,
  pipelining: HTTP_PIPELINE,
  keepAliveTimeout: 60_000,
  keepAliveMaxTimeout: 120_000,
});

// ============= 初始化 =============
const chain = defineChain({
  id: CHAIN_ID,
  name: 'flashblocks-l2',
  nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [READ_RPC_URL] } },
});

const publicClient = createPublicClient({ chain, transport: http(READ_RPC_URL) });
const funder       = privateKeyToAccount(FUNDER_KEY);

const senders = Array.from({ length: N_SENDERS }, () => privateKeyToAccount(generatePrivateKey()));
const senderNonce = new Array(N_SENDERS).fill(0);

const stats = {
  bundlesSent: 0,
  bundleOk: 0,
  bundleErr: 0,
  errSamples: [],
  latMs: [],   // 收到 RPC 响应的延迟（不等于 inclusion 延迟）
};

// ============= Bundle 发送 =============
async function rpcCall(method, params) {
  const t0 = Date.now();
  const res = await undiciFetch(RPC_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', method, params, id: 1 }),
    dispatcher: httpAgent,
  });
  // 区分 "JSON-RPC 错误"（HTTP 200，body 里 error 字段）vs
  //     "HTTP 层错误"（reth max-connections 满返回 503 + plain text "Too many connections"）
  if (!res.ok) {
    const txt = await res.text();
    return { error: { code: -res.status, message: `HTTP ${res.status}: ${txt.slice(0, 120)}` }, _latMs: Date.now() - t0 };
  }
  const ct = res.headers.get('content-type') || '';
  if (!ct.includes('json')) {
    const txt = await res.text();
    return { error: { code: -1, message: `non-json (${ct}): ${txt.slice(0, 120)}` }, _latMs: Date.now() - t0 };
  }
  const json = await res.json();
  return { ...json, _latMs: Date.now() - t0 };
}

async function sendBundle(rawTxs, blockNumber) {
  return rpcCall('eth_sendBundle', [{
    txs: rawTxs,
    blockNumber: toHex(blockNumber),
  }]);
}

// ============= Setup：funder → senders 注资 =============
async function setup() {
  console.log(`[setup] chainId=${CHAIN_ID}  rpc=${RPC_URL}  read=${READ_RPC_URL}`);
  console.log(`[setup] funder=${funder.address}`);
  console.log(`[setup] generating ${N_SENDERS} ephemeral senders, funding ${FUNDING_ETH} ETH each`);

  const funderBalance = await publicClient.getBalance({ address: funder.address });
  const funderNonce   = await publicClient.getTransactionCount({ address: funder.address });
  const head          = await publicClient.getBlockNumber();
  console.log(`[setup] funder balance=${funderBalance}  nonce=${funderNonce}  head=${head}`);

  const need = parseEther(FUNDING_ETH) * BigInt(N_SENDERS);
  if (funderBalance < need) {
    console.error(`[setup] FATAL: funder balance ${funderBalance} < need ${need}`);
    process.exit(1);
  }

  const fundingTxs = [];
  for (let i = 0; i < N_SENDERS; i++) {
    const tx = await funder.signTransaction({
      to: senders[i].address,
      value: parseEther(FUNDING_ETH),
      nonce: funderNonce + i,
      gas: 21000n,
      maxFeePerGas: parseGwei(GAS_PRICE_GWEI),
      maxPriorityFeePerGas: parseGwei(GAS_PRICE_GWEI),
      chainId: CHAIN_ID,
    });
    fundingTxs.push(tx);
  }
  console.log(`[setup] signed ${fundingTxs.length} funding txs`);

  // op-rbuilder v0.2.x 限制：bundle 必须 exactly 1 笔 tx。
  // 所以 funding 阶段并发发 N 个单 tx bundle，全部 target 同一个 block。
  // 这些 bundle 是同一个 funder 的连续 nonce，builder 可以全部塞进一个 block (50 × 21k = 1.05M gas)。
  console.log(`[setup] sending ${N_SENDERS} single-tx bundles to op-rbuilder (target block=${head + 1n})`);
  let fundOk = 0, fundErr = 0;
  const fundErrSamples = [];
  await Promise.all(fundingTxs.map(async (raw) => {
    const r = await sendBundle([raw], head + 1n);
    if (r.error) {
      fundErr++;
      if (fundErrSamples.length < 3) fundErrSamples.push(r.error.message);
    } else {
      fundOk++;
    }
  }));
  console.log(`[setup] funding bundles result: ok=${fundOk}, err=${fundErr}`);
  if (fundErrSamples.length) {
    console.log(`[setup] funding error samples:`);
    fundErrSamples.forEach((e, i) => console.log(`  [${i}] ${e.slice(0, 200)}`));
  }
  if (fundOk === 0) {
    console.error(`[setup] FATAL: no funding bundle accepted, abort`);
    process.exit(1);
  }

  // 等 senders[0] 余额到位（最长 30s）
  console.log(`[setup] waiting for senders to be funded...`);
  for (let attempt = 0; attempt < 30; attempt++) {
    await new Promise(r => setTimeout(r, 1000));
    const bal0 = await publicClient.getBalance({ address: senders[0].address });
    const balLast = await publicClient.getBalance({ address: senders[N_SENDERS - 1].address });
    if (bal0 > 0n && balLast > 0n) {
      console.log(`[setup] all senders funded after ${attempt + 1}s (sender[0]=${bal0}, sender[last]=${balLast})`);
      return;
    }
    if ((attempt + 1) % 5 === 0) {
      console.log(`[setup] still waiting... (sender[0]=${bal0}, sender[last]=${balLast})`);
    }
  }
  console.error(`[setup] FATAL: senders not funded after 30s. Bundle may have been dropped by builder.`);
  process.exit(2);
}

// ============= Spam 主循环 =============
// 缓存 head 避免每个 tx 都查（高 TPS 时 RPC 会被打爆）
let cachedHead = 0n;
let headTimer = null;

async function startHeadUpdater() {
  const tick = async () => {
    try { cachedHead = await publicClient.getBlockNumber(); } catch (e) {}
  };
  await tick();
  headTimer = setInterval(tick, 500);
}

function stopHeadUpdater() {
  if (headTimer) { clearInterval(headTimer); headTimer = null; }
}

async function buildAndSendOne(senderIdx) {
  const sender = senders[senderIdx];
  const nonce  = senderNonce[senderIdx]++;
  const recipient = senders[(senderIdx + 1) % N_SENDERS].address;

  let raw;
  try {
    raw = await sender.signTransaction({
      to: recipient,
      value: 0n,
      nonce,
      gas: 21000n,
      maxFeePerGas: parseGwei(GAS_PRICE_GWEI),
      maxPriorityFeePerGas: parseGwei(GAS_PRICE_GWEI),
      chainId: CHAIN_ID,
    });
  } catch (e) {
    stats.bundleErr++;
    if (stats.errSamples.length < ERR_SAMPLES_MAX) stats.errSamples.push(`sign: ${e.message}`);
    return;
  }

  const r = await sendBundle([raw], cachedHead + BigInt(BUNDLE_BLOCK_OFS));
  stats.bundlesSent++;
  stats.latMs.push(r._latMs);
  if (r.error) {
    stats.bundleErr++;
    if (stats.errSamples.length < ERR_SAMPLES_MAX) stats.errSamples.push(r.error.message);
  } else {
    stats.bundleOk++;
  }
}

async function spam() {
  console.log(`[spam] target_tps=${TARGET_TPS}  n_senders=${N_SENDERS}  duration=${DURATION_S}s  bundle_block_ofs=${BUNDLE_BLOCK_OFS}`);
  await startHeadUpdater();
  const start = Date.now();
  const endAt = start + DURATION_S * 1000;
  const intervalMs = 1000 / TARGET_TPS;
  let nextSendIdx = 0;
  let lastSnap = { ...stats, bundlesSent: 0, bundleOk: 0, bundleErr: 0 };
  let lastSnapAt = start;

  // 周期性进度报告
  const reportTimer = setInterval(async () => {
    const now = Date.now();
    const elapsedSec = (now - lastSnapAt) / 1000;
    const dSent = stats.bundlesSent - lastSnap.bundlesSent;
    const dOk = stats.bundleOk - lastSnap.bundleOk;
    const dErr = stats.bundleErr - lastSnap.bundleErr;
    const ratesSent = (dSent / elapsedSec).toFixed(0);
    const ratesOk   = (dOk / elapsedSec).toFixed(0);
    const ratesErr  = (dErr / elapsedSec).toFixed(0);
    let head = '?';
    try { head = await publicClient.getBlockNumber(); } catch (e) {}
    console.log(
      `[+${((now - start) / 1000).toFixed(0)}s] head=${head}  rate sent=${ratesSent}/s ok=${ratesOk}/s err=${ratesErr}/s  | total sent=${stats.bundlesSent} ok=${stats.bundleOk} err=${stats.bundleErr}`
    );
    lastSnap = { bundlesSent: stats.bundlesSent, bundleOk: stats.bundleOk, bundleErr: stats.bundleErr };
    lastSnapAt = now;
  }, REPORT_INTERVAL_S * 1000);

  const tick = async () => {
    const now = Date.now();
    if (now >= endAt) return;
    const elapsedMs = now - start;
    const targetTxCount = Math.floor(elapsedMs / intervalMs);
    while (nextSendIdx < targetTxCount) {
      buildAndSendOne(nextSendIdx % N_SENDERS).catch(e => {
        stats.bundleErr++;
        if (stats.errSamples.length < ERR_SAMPLES_MAX) stats.errSamples.push(`unhandled: ${e.message}`);
      });
      nextSendIdx++;
    }
    setImmediate(tick);
  };
  tick();

  await new Promise(r => setTimeout(r, DURATION_S * 1000));
  clearInterval(reportTimer);
  stopHeadUpdater();
  const drainSec = parseInt(process.env.DRAIN_S || '15');
  console.log(`[spam] duration done, draining in-flight bundles for ${drainSec}s...`);
  await new Promise(r => setTimeout(r, drainSec * 1000));
}

// ============= Final Report =============
async function report() {
  console.log('\n========== FINAL REPORT ==========');
  console.log(`bundles sent:  ${stats.bundlesSent}`);
  console.log(`bundles ok:    ${stats.bundleOk}`);
  console.log(`bundles err:   ${stats.bundleErr}`);
  console.log(`error rate:    ${stats.bundlesSent > 0 ? (100 * stats.bundleErr / stats.bundlesSent).toFixed(1) : 0}%`);
  if (stats.errSamples.length) {
    console.log(`error samples:`);
    stats.errSamples.forEach((e, i) => console.log(`  [${i}] ${e.slice(0, 200)}`));
  }
  // RPC 延迟分布
  if (stats.latMs.length) {
    const sorted = [...stats.latMs].sort((a, b) => a - b);
    const p = (q) => sorted[Math.floor(sorted.length * q)];
    console.log(`rpc lat (ms): p50=${p(0.5)} p95=${p(0.95)} p99=${p(0.99)} max=${sorted[sorted.length - 1]}`);
  }

  // 链上实际 user TPS（30 block 窗口）
  console.log('\n--- on-chain measurement (last 30 blocks) ---');
  const head = await publicClient.getBlockNumber();
  const start = head - 30n;
  let totalTxs = 0;
  let userTxs = 0;
  let maxTxs = 0;
  for (let b = start; b <= head; b++) {
    try {
      const block = await publicClient.getBlock({ blockNumber: b, includeTransactions: false });
      totalTxs += block.transactions.length;
      // user tx 估算：减掉 op-stack 默认 ~3 笔 system tx（deposit + fee vault + builder attestation）
      userTxs  += Math.max(0, block.transactions.length - 3);
      if (block.transactions.length > maxTxs) maxTxs = block.transactions.length;
    } catch (e) {}
  }
  console.log(`head=${head}  window=${start}~${head}`);
  console.log(`total txs (30 blocks): ${totalTxs}  approx chain TPS: ${(totalTxs / 30).toFixed(1)}`);
  console.log(`user  txs (30 blocks): ${userTxs}   approx user  TPS: ${(userTxs / 30).toFixed(1)}`);
  console.log(`max txs in single block: ${maxTxs}`);

  // === 关键 inclusion 验证：全 sender 的链上 nonce 总和 ===
  // 链上 nonce = 该地址在 canonical chain 上已确认的 tx 数。
  // 如果 sum(onchain_nonce) == sum(local_sent_nonce)，说明 100% 的 spam tx 都已 inclusion。
  console.log('\n--- on-chain inclusion check (all senders, hard evidence) ---');
  let totalOnchainNonce = 0n;
  let lostSenders = 0;
  let lostTxs = 0;
  for (let i = 0; i < N_SENDERS; i++) {
    try {
      const onchain = await publicClient.getTransactionCount({ address: senders[i].address });
      totalOnchainNonce += BigInt(onchain);
      const local = senderNonce[i];
      const lost = local - Number(onchain);
      if (lost > 0) {
        lostSenders++;
        lostTxs += lost;
      }
    } catch (e) {}
  }
  const totalLocalNonce = senderNonce.reduce((a, b) => a + b, 0);
  const inclusionRate = totalLocalNonce > 0
    ? (100 * Number(totalOnchainNonce) / totalLocalNonce).toFixed(2)
    : '0.00';
  console.log(`local sent total: ${totalLocalNonce} txs (across ${N_SENDERS} senders)`);
  console.log(`on-chain nonce total: ${totalOnchainNonce}`);
  console.log(`inclusion rate: ${inclusionRate}%  (${totalOnchainNonce} on-chain / ${totalLocalNonce} sent)`);
  if (lostTxs > 0) {
    console.log(`-> ${lostSenders} senders have nonce gap, total ${lostTxs} txs not yet on-chain`);
  } else {
    console.log(`-> 100%  ALL sent txs verified on-chain`);
  }

  // 抽样：检查 sender[0] / sender[mid] / sender[last] 的最新 tx receipt
  console.log('\n--- sample tx receipt sanity check (sender[0] / mid / last) ---');
  for (const idx of [0, Math.floor(N_SENDERS / 2), N_SENDERS - 1]) {
    const addr = senders[idx].address;
    try {
      const onchainNonce = await publicClient.getTransactionCount({ address: addr });
      const balance = await publicClient.getBalance({ address: addr });
      console.log(`sender[${idx}] ${addr}: on-chain nonce=${onchainNonce}  local sent=${senderNonce[idx]}  balance=${balance} wei`);
    } catch (e) {
      console.log(`sender[${idx}] query error: ${e.message}`);
    }
  }
}

// ============= main =============
(async () => {
  try {
    await setup();
    await spam();
    await report();
  } catch (e) {
    console.error('FATAL:', e);
    process.exit(99);
  } finally {
    try { await httpAgent.close(); } catch (_) {}
  }
})();
