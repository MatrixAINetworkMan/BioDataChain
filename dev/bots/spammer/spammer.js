#!/usr/bin/env node
// =============================================================================
// MAN L2 transaction spammer
//
// 目的：给 Blockscout 浏览器制造持续的真实交易活动，让 dashboard、tx 列表、
// 地址列表都"动起来"，便于演示和压测前端实时刷新。
//
// 子命令（在本目录下跑）：
//   npm install              # 一次性
//   npm run init             # 生成 5642 钱包，存到 wallets.json（含私钥，已 gitignore）
//
//   # —— 模式 A：拟真模式（推荐，看着像真的 demo）——
//   npm run grow             # 渐进式上线（sigmoid 曲线 + burst 噪音）
//                            # 同时跑：deployer 一波一波激活新钱包 + 已激活钱包互转
//                            # 默认 24 小时把 5642 个地址全部激活完
//                            # 可中断重启，状态存在 active.json
//
//   # —— 模式 B：暴力模式（一次性灌满，看 TPS / 索引压力）——
//   npm run fund             # 从 deployer 给每个钱包打随机 200-10000 MAN
//   npm run spam             # 每秒挑 3-15 个钱包各发一笔 3-5% 余额的转账（永久跑）
//
//   npm run status           # 看链状态 / 钱包数 / 激活进度 / 抽样余额
//
// 也可直接：node spammer.js {init|grow|fund|spam|status}
//
// 环境变量（自动从 dev/.env 读，可覆盖）：
//   RPC_URL                  默认 http://localhost:${L2_RPC_PORT}
//   L2_CHAIN_ID              链 ID（必需）
//   DEPLOYER_PRIVATE_KEY     funding 用（fund/grow/status 命令需要）
//   WALLET_COUNT             默认 5642
//   FUND_MIN / FUND_MAX      默认 200 / 10000 (MAN) — 单钱包激活时的随机区间
//   SPAM_MIN / SPAM_MAX      默认 3 / 15（每秒最大发起的 tx 数）
//   SPAM_PCT_MIN / MAX       默认 0.03 / 0.05（金额占余额比例）
//   GAS_PRICE_GWEI           默认 1（gas tracker ~0.9 gwei，1 必稳）
//   WALLETS_FILE             默认 ./wallets.json
//
//   # —— grow 模式专属 ——
//   GROWTH_DURATION          默认 86400（秒）— 多久把 TARGET 个地址全部激活完
//   GROWTH_INITIAL           默认 30        — 启动时立刻激活的种子钱包数
//   GROWTH_TARGET            默认 WALLET_COUNT — 最终激活到这个数量
//   GROWTH_CURVE             默认 sigmoid   — sigmoid | linear | log
//   GROWTH_BURST_PROB        默认 0.25      — 每个 200ms tick 触发激活 burst 的概率
//   GROWTH_BURST_MAX         默认 5         — 单次 burst 最多激活几个
//
// 注意：
//   - wallets.json 含 5642 个私钥，绝对不要 commit / 不要发外网；仅 dev 用
//   - 5642 × 200~10000 平均 ≈ 28M MAN，远超 deployer 创世余额（10k MAN）。
//     真要按这个量级跑，必须先把 deployer 创世余额调高（改 op-deployer intent
//     重建链）；否则把 WALLET_COUNT 或 FUND_MAX 调小试跑。脚本 fund 时会自动
//     preflight 检查并给出建议。
// =============================================================================

import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  formatEther,
  parseGwei,
  defineChain,
  encodeFunctionData,
  decodeFunctionResult,
} from 'viem';
import { privateKeyToAccount, generatePrivateKey } from 'viem/accounts';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// -----------------------------------------------------------------------------
// 极简 .env 加载器（不引外部 dotenv 依赖；仅认 KEY=VALUE 形式）
// -----------------------------------------------------------------------------
function loadEnvFile(envPath) {
  if (!fs.existsSync(envPath)) return;
  for (const raw of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const m = line.match(/^([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$/);
    if (!m) continue;
    if (process.env[m[1]] !== undefined) continue; // 已显式 export 不覆盖
    let val = m[2].trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    process.env[m[1]] = val;
  }
}
// dev/.env 在脚本上 3 级目录：bots/spammer → bots → dev
loadEnvFile(path.resolve(__dirname, '../../.env'));

// -----------------------------------------------------------------------------
// 配置
// -----------------------------------------------------------------------------
const cfg = {
  rpcUrl: process.env.RPC_URL || `http://localhost:${process.env.L2_RPC_PORT || '9545'}`,
  chainId: parseInt(process.env.L2_CHAIN_ID || '0'),
  deployerKey: process.env.DEPLOYER_PRIVATE_KEY,
  walletCount: parseInt(process.env.WALLET_COUNT || '5642'),
  fundMin: parseFloat(process.env.FUND_MIN || '200'),
  fundMax: parseFloat(process.env.FUND_MAX || '10000'),
  spamMin: parseInt(process.env.SPAM_MIN || '3'),
  spamMax: parseInt(process.env.SPAM_MAX || '15'),
  pctMin: parseFloat(process.env.SPAM_PCT_MIN || '0.03'),
  pctMax: parseFloat(process.env.SPAM_PCT_MAX || '0.05'),
  walletsFile: path.resolve(__dirname, process.env.WALLETS_FILE || 'wallets.json'),
  gasPrice: parseGwei(process.env.GAS_PRICE_GWEI || '1'),
  // grow 专属
  growthDuration: parseFloat(process.env.GROWTH_DURATION || '86400'),
  growthInitial: parseInt(process.env.GROWTH_INITIAL || '30'),
  growthTarget: parseInt(process.env.GROWTH_TARGET || '0'), // 0 = WALLET_COUNT
  growthCurve: (process.env.GROWTH_CURVE || 'sigmoid').toLowerCase(),
  growthBurstProb: parseFloat(process.env.GROWTH_BURST_PROB || '0.25'),
  growthBurstMax: parseInt(process.env.GROWTH_BURST_MAX || '5'),
  activeFile: path.resolve(__dirname, process.env.ACTIVE_FILE || 'active.json'),
};
if (cfg.growthTarget === 0) cfg.growthTarget = cfg.walletCount;

if (!cfg.chainId) {
  console.error('❌ 缺 L2_CHAIN_ID（在 dev/.env 里，或 L2_CHAIN_ID=42170 显式传）');
  process.exit(1);
}

const chain = defineChain({
  id: cfg.chainId,
  name: 'MAN',
  nativeCurrency: { name: 'MAN', symbol: 'MAN', decimals: 18 },
  rpcUrls: { default: { http: [cfg.rpcUrl] } },
});

const publicClient = createPublicClient({ chain, transport: http(cfg.rpcUrl) });

// -----------------------------------------------------------------------------
// 工具
// -----------------------------------------------------------------------------
function loadWallets() {
  if (!fs.existsSync(cfg.walletsFile)) return [];
  return JSON.parse(fs.readFileSync(cfg.walletsFile, 'utf8'));
}
function saveWallets(wallets) {
  // 一行一个钱包，diff/grep 友好；首尾 [ ] 自带
  const body = wallets.map(w => '  ' + JSON.stringify(w)).join(',\n');
  fs.writeFileSync(cfg.walletsFile, '[\n' + body + '\n]\n', { mode: 0o600 });
}
function rndInt(min, max) { return min + Math.floor(Math.random() * (max - min + 1)); }
function rndFloat(min, max) { return min + Math.random() * (max - min); }
function pickRandomDistinct(arr, n) {
  const out = [];
  const used = new Set();
  while (out.length < n && used.size < arr.length) {
    const i = Math.floor(Math.random() * arr.length);
    if (used.has(i)) continue;
    used.add(i);
    out.push(arr[i]);
  }
  return out;
}

// -----------------------------------------------------------------------------
// init: 生成 N 个钱包
// -----------------------------------------------------------------------------
async function cmdInit() {
  let wallets = loadWallets();
  console.log(`已有 ${wallets.length} / 目标 ${cfg.walletCount}`);
  if (wallets.length >= cfg.walletCount) {
    console.log('✅ 数量已达标，跳过生成');
    return;
  }
  const need = cfg.walletCount - wallets.length;
  console.log(`==> 生成 ${need} 个新钱包...`);
  for (let i = 0; i < need; i++) {
    const pk = generatePrivateKey();
    const acc = privateKeyToAccount(pk);
    wallets.push({ address: acc.address, privateKey: pk });
    if ((i + 1) % 500 === 0) process.stdout.write(`\r    ${i + 1}/${need}`);
  }
  console.log('');
  saveWallets(wallets);
  console.log(`✅ 共 ${wallets.length} 个，已存到 ${cfg.walletsFile}（mode 0600）`);
  console.log(`   ⚠️  此文件含 ${wallets.length} 个私钥，绝对不要 commit / 发外网`);
}

// -----------------------------------------------------------------------------
// fund: 从 deployer 给每个钱包打随机 [FUND_MIN, FUND_MAX] MAN
// -----------------------------------------------------------------------------
async function cmdFund() {
  if (!cfg.deployerKey) {
    console.error('❌ 缺 DEPLOYER_PRIVATE_KEY');
    process.exit(1);
  }
  const wallets = loadWallets();
  if (!wallets.length) {
    console.error('❌ 没钱包，先 npm run init');
    process.exit(1);
  }

  const deployer = privateKeyToAccount(cfg.deployerKey);
  const wc = createWalletClient({ account: deployer, chain, transport: http(cfg.rpcUrl) });

  const [startNonce, balance] = await Promise.all([
    publicClient.getTransactionCount({ address: deployer.address }),
    publicClient.getBalance({ address: deployer.address }),
  ]);
  console.log(`==> Deployer ${deployer.address}`);
  console.log(`    余额      ${formatEther(balance)} MAN`);
  console.log(`    起始 nonce ${startNonce}`);

  // 算每个钱包的金额 + 跳过已经有钱的
  const amounts = [];
  let toFund = 0;
  for (let i = 0; i < wallets.length; i++) {
    const a = rndFloat(cfg.fundMin, cfg.fundMax);
    amounts.push(parseEther(a.toFixed(6)));
    toFund++;
  }

  const total = amounts.reduce((a, b) => a + b, 0n);
  const gasCost = BigInt(toFund) * 21000n * cfg.gasPrice;
  const need = total + gasCost;

  console.log(`==> 准备给 ${toFund} 个钱包打钱（${cfg.fundMin}-${cfg.fundMax} MAN 随机）`);
  console.log(`    转出总额 ${formatEther(total)} MAN`);
  console.log(`    Gas 总额 ${formatEther(gasCost)} MAN`);
  console.log(`    合计需要 ${formatEther(need)} MAN`);

  if (balance < need) {
    const balF = parseFloat(formatEther(balance));
    // 给个能装下当前余额的建议组合
    const safePerWallet = Math.floor((balF * 0.95) / toFund);
    console.error('');
    console.error(`❌ Deployer 余额不够（差 ${formatEther(need - balance)} MAN）`);
    console.error('');
    console.error('   方案 A：缩小规模重跑（最简单）');
    console.error(`           WALLET_COUNT=100 FUND_MIN=10 FUND_MAX=50 npm run init && npm run fund`);
    console.error('   方案 B：保持 5642 钱包，按 deployer 实际余额均分');
    console.error(`           FUND_MIN=${Math.max(1, Math.floor(safePerWallet * 0.5))} FUND_MAX=${Math.max(1, safePerWallet)} npm run fund`);
    console.error('   方案 C：改 op-deployer intent 把 deployer 创世余额拉高，重建链');
    console.error('           （NATIVE_INITIAL_LIQUIDITY 是 NativeAssetLiquidity 预留池，');
    console.error('            想从那里调到 deployer 要走 LiquidityController 合约）');
    process.exit(1);
  }

  // 分批并发签发；每批 200 笔，等本批全发出再发下一批，防 mempool 撑爆
  const BATCH = 200;
  let sent = 0, failed = 0, lastHash;
  const t0 = Date.now();
  for (let i = 0; i < wallets.length; i += BATCH) {
    const slice = wallets.slice(i, i + BATCH);
    const promises = slice.map((w, j) => {
      const nonce = startNonce + i + j;
      return wc.sendTransaction({
        to: w.address,
        value: amounts[i + j],
        nonce,
        gas: 21000n,
        maxFeePerGas: MAX_FEE_PER_GAS,
        maxPriorityFeePerGas: MAX_PRIORITY_FEE_PER_GAS,
      }).catch(err => {
        failed++;
        console.error(`\n  ⚠️ tx nonce=${nonce} 失败：${err.shortMessage || err.message}`);
        return null;
      });
    });
    const hashes = await Promise.all(promises);
    const ok = hashes.filter(h => h);
    if (ok.length) lastHash = ok[ok.length - 1];
    sent += slice.length;
    process.stdout.write(`\r    已发 ${sent}/${wallets.length}（成功 ${sent - failed}，失败 ${failed}）`);
  }
  console.log('');
  if (lastHash) {
    console.log(`==> 等最后一笔 receipt（${lastHash.slice(0, 18)}...）...`);
    await publicClient.waitForTransactionReceipt({ hash: lastHash, timeout: 90_000 });
  }
  const dt = ((Date.now() - t0) / 1000).toFixed(1);
  console.log(`✅ Funding 完成（${dt}s，成功 ${sent - failed}，失败 ${failed}）`);
}

// -----------------------------------------------------------------------------
// 共享：单笔随机互转。
//   sender         viem account 对象（有私钥）
//   state          Map<address, { account, nonce, balance }>
//   recipientPool  收款候选池（数组，活的引用 — grow 模式会动态 push）
//   stats          { ok, fail }
// 设计要点：
//   - fire-and-forget 由调用方决定（这里是 async，但 caller 通常不 await）
//   - 本地 nonce / balance 先扣，失败回滚（避免一笔挂掉拖累后面）
//   - nonce 错位时重新从 RPC 同步本地 nonce
// -----------------------------------------------------------------------------
async function spamSendOne(sender, state, recipientPool, stats) {
  const s = state.get(sender.address);
  if (!s || s.balance < parseEther('1')) return;

  let to;
  for (let t = 0; t < 10; t++) {
    to = recipientPool[Math.floor(Math.random() * recipientPool.length)];
    if (to && to.address !== sender.address) break;
    to = null;
  }
  if (!to) return;

  const pct = rndFloat(cfg.pctMin, cfg.pctMax);
  // bigint × float：用 1e6 精度
  const value = (s.balance * BigInt(Math.floor(pct * 1_000_000))) / 1_000_000n;
  if (value === 0n) return;

  const nonce = s.nonce++;
  s.balance -= value;
  const r = state.get(to.address);
  if (r) r.balance += value;

  try {
    const signed = await sender.signTransaction({
      type: 'eip1559',
      chainId: cfg.chainId,
      to: to.address,
      value,
      nonce,
      gas: 21000n,
      maxFeePerGas: MAX_FEE_PER_GAS,
      maxPriorityFeePerGas: MAX_PRIORITY_FEE_PER_GAS,
    });
    await publicClient.sendRawTransaction({ serializedTransaction: signed });
    stats.ok++;
  } catch (err) {
    stats.fail++;
    s.nonce = nonce; // 不能直接 -- 因为后续 tick 可能已经又 ++ 了
    s.balance += value;
    if (r) r.balance -= value;
    const msg = (err.shortMessage || err.message || '').toLowerCase();
    if (msg.includes('nonce') || msg.includes('underpriced') || msg.includes('replacement')) {
      try { s.nonce = await publicClient.getTransactionCount({ address: sender.address }); } catch {}
    }
  }
}

// -----------------------------------------------------------------------------
// spam: 每秒 3-15 笔随机互转（要求 fund 已跑过；不做激活；模式 B）
// -----------------------------------------------------------------------------
async function cmdSpam() {
  const wallets = loadWallets();
  if (!wallets.length) { console.error('❌ 没钱包'); process.exit(1); }
  const accounts = wallets.map(w => privateKeyToAccount(w.privateKey));

  console.log(`==> 初始化 ${wallets.length} 个钱包的 nonce / balance（30 并发，约 10-30s）...`);
  const state = new Map();
  const PARALLEL = 30;
  const t0 = Date.now();
  for (let i = 0; i < accounts.length; i += PARALLEL) {
    const slice = accounts.slice(i, i + PARALLEL);
    await Promise.all(slice.map(async acc => {
      const [nonce, balance] = await Promise.all([
        publicClient.getTransactionCount({ address: acc.address }),
        publicClient.getBalance({ address: acc.address }),
      ]);
      state.set(acc.address, { account: acc, nonce, balance });
    }));
    process.stdout.write(`\r    ${Math.min(i + PARALLEL, accounts.length)}/${accounts.length}`);
  }
  console.log('');
  console.log(`    用时 ${((Date.now() - t0) / 1000).toFixed(1)}s`);

  const totalBal = [...state.values()].reduce((a, b) => a + b.balance, 0n);
  const funded = [...state.values()].filter(s => s.balance > parseEther('1')).length;
  console.log(`    汇总余额 ${formatEther(totalBal)} MAN，可用钱包（>1 MAN）${funded}/${accounts.length}`);
  if (funded < cfg.spamMax) {
    console.error('❌ 可用钱包数 < 每秒最大发起数，先 npm run fund');
    process.exit(1);
  }

  const stats = { ok: 0, fail: 0, started: Date.now() };

  console.log('');
  console.log(`==> 开始 spam`);
  console.log(`    - 每秒挑 ${cfg.spamMin}-${cfg.spamMax} 个钱包`);
  console.log(`    - 各发一笔 ${(cfg.pctMin * 100).toFixed(1)}%-${(cfg.pctMax * 100).toFixed(1)}% 余额给随机其他钱包`);
  console.log(`    - Gas price ${formatEther(cfg.gasPrice)} ETH/gas (= ${process.env.GAS_PRICE_GWEI || '1'} gwei)`);
  console.log(`    - Ctrl+C 优雅退出`);
  console.log('');

  const tickHandle = setInterval(() => {
    const n = rndInt(cfg.spamMin, cfg.spamMax);
    const senders = pickRandomDistinct(accounts, n);
    senders.forEach(s => spamSendOne(s, state, accounts, stats));
  }, 1000);

  const statHandle = setInterval(() => {
    const elapsed = (Date.now() - stats.started) / 1000;
    const tps = stats.ok / elapsed;
    process.stdout.write(
      `\r[${elapsed.toFixed(0)}s] ok=${stats.ok}  fail=${stats.fail}  avg-tps=${tps.toFixed(2)}     `
    );
  }, 2000);

  const onShutdown = (sig) => {
    clearInterval(tickHandle);
    clearInterval(statHandle);
    const dt = ((Date.now() - stats.started) / 1000).toFixed(1);
    console.log('');
    console.log(`==> 收到 ${sig}，停止`);
    console.log(`    总成功 ${stats.ok}，失败 ${stats.fail}，运行 ${dt}s`);
    process.exit(0);
  };
  process.on('SIGINT', () => onShutdown('SIGINT'));
  process.on('SIGTERM', () => onShutdown('SIGTERM'));
}

// -----------------------------------------------------------------------------
// grow: 渐进式上线（拟真模式 / 模式 A）
//
//   - 用 sigmoid 曲线（默认）控制"应有的已激活钱包数"随时间增长
//     t=0     ≈ GROWTH_INITIAL (默认 30)
//     t=T/2   ≈ (INITIAL + TARGET) / 2
//     t=T     ≈ TARGET (默认 5642)
//   - 每 200ms 一个 tick，按 GROWTH_BURST_PROB 概率决定本 tick 要不要激活
//     一波（避免均匀的"每秒固定 N 个新地址"那种太规整的画面）
//   - 单 burst 激活 1-GROWTH_BURST_MAX 个钱包，每个由 deployer 转一笔随机
//     [FUND_MIN, FUND_MAX] MAN 上去
//   - 已激活的钱包参与互转：每秒 effective_max ∈ [3, 15] 笔，按当前激活数
//     线性 ramp（pool 小时不会硬要 15 tps）
//   - 状态持久化在 active.json：可中断、重启续跑（startedAt 不变 → 曲线连续）
//
// 数学说明（sigmoid）：
//   target(elapsed) = INITIAL + (TARGET - INITIAL) * sigmoid(12*(t/T - 0.5))
//   12 这个系数让 sigmoid 在 [0, T] 内基本走完 0 → 1（两端 ≈ 0.002 / 0.998）
// -----------------------------------------------------------------------------
function targetActiveAt(elapsedSec) {
  const T = cfg.growthDuration;
  const init = Math.min(cfg.growthInitial, cfg.growthTarget);
  const tgt = cfg.growthTarget;
  if (T <= 0 || elapsedSec >= T) return tgt;
  if (elapsedSec <= 0) return init;
  if (cfg.growthCurve === 'linear') {
    return Math.round(init + (tgt - init) * (elapsedSec / T));
  }
  if (cfg.growthCurve === 'log') {
    // 前期慢速、后期更慢，几乎 log
    const x = Math.log1p(elapsedSec) / Math.log1p(T);
    return Math.round(init + (tgt - init) * x);
  }
  // sigmoid (默认)
  const x = 12 * (elapsedSec / T - 0.5);
  const s = 1 / (1 + Math.exp(-x));
  return Math.round(init + (tgt - init) * s);
}

async function cmdGrow() {
  if (!cfg.deployerKey) { console.error('❌ 缺 DEPLOYER_PRIVATE_KEY'); process.exit(1); }
  const wallets = loadWallets();
  if (!wallets.length) { console.error('❌ 没钱包，先 npm run init'); process.exit(1); }

  const deployer = privateKeyToAccount(cfg.deployerKey);
  const wc = createWalletClient({ account: deployer, chain, transport: http(cfg.rpcUrl) });

  // ---- 加载 / 初始化 active 状态 ----
  let activeState;
  if (fs.existsSync(cfg.activeFile)) {
    activeState = JSON.parse(fs.readFileSync(cfg.activeFile, 'utf8'));
    console.log(`==> 恢复已有 active.json：startedAt=${new Date(activeState.startedAt).toISOString()}，已激活 ${activeState.activated.length}`);
  } else {
    activeState = { startedAt: Date.now(), activated: [] };
    console.log(`==> 全新启动，startedAt=${new Date(activeState.startedAt).toISOString()}`);
  }
  const saveActive = () => {
    const body = activeState.activated.map(a => '    ' + JSON.stringify(a)).join(',\n');
    fs.writeFileSync(cfg.activeFile, `{\n  "startedAt": ${activeState.startedAt},\n  "activated": [\n${body}\n  ]\n}\n`);
  };

  const activeAddrs = new Set(activeState.activated.map(a => a.address));
  const walletsByAddr = new Map(wallets.map(w => [w.address, w]));
  const inactive = wallets.filter(w => !activeAddrs.has(w.address));
  const activeAccounts = []; // viem account 对象，激活顺序

  // ---- 加载已激活钱包的 nonce/balance ----
  const state = new Map();
  if (activeState.activated.length) {
    console.log(`==> 加载 ${activeState.activated.length} 个已激活钱包的 nonce/balance...`);
    const PARALLEL = 30;
    for (let i = 0; i < activeState.activated.length; i += PARALLEL) {
      const slice = activeState.activated.slice(i, i + PARALLEL);
      await Promise.all(slice.map(async a => {
        const w = walletsByAddr.get(a.address);
        if (!w) return; // active.json 里有但 wallets.json 里没（被清过 wallets.json）
        const acc = privateKeyToAccount(w.privateKey);
        const [nonce, balance] = await Promise.all([
          publicClient.getTransactionCount({ address: acc.address }),
          publicClient.getBalance({ address: acc.address }),
        ]);
        state.set(acc.address, { account: acc, nonce, balance });
        activeAccounts.push(acc);
      }));
      process.stdout.write(`\r    ${Math.min(i + PARALLEL, activeState.activated.length)}/${activeState.activated.length}`);
    }
    console.log('');
  }

  // ---- 准备 deployer ----
  let deployerNonce = await publicClient.getTransactionCount({ address: deployer.address });
  let deployerBal = await publicClient.getBalance({ address: deployer.address });
  console.log(`==> Deployer ${deployer.address}`);
  console.log(`    余额 ${formatEther(deployerBal)} MAN，nonce ${deployerNonce}`);
  console.log(`    曲线 ${cfg.growthCurve}，${cfg.growthInitial} → ${cfg.growthTarget}，${(cfg.growthDuration / 3600).toFixed(1)}h`);
  console.log(`    每钱包激活金额 ${cfg.fundMin}-${cfg.fundMax} MAN 随机`);
  console.log(`    Burst 概率 ${cfg.growthBurstProb}（每 200ms tick），单 burst 1-${cfg.growthBurstMax} 钱包`);

  // ---- preflight：deployer 余额够不够把 GROWTH_TARGET 全部按 FUND_MIN 上线？----
  // 不够就直接退出，给具体的可行 FUND_MIN/FUND_MAX。允许 FORCE_GROW=1 强行跑。
  const remaining = cfg.growthTarget - activeAccounts.length;
  if (remaining > 0) {
    const reserveGas = BigInt(remaining) * 21000n * cfg.gasPrice * 2n; // 留 2x gas 余量
    const minBudget = BigInt(remaining) * parseEther(cfg.fundMin.toString());
    const minNeed = minBudget + reserveGas;
    if (deployerBal < minNeed && !process.env.FORCE_GROW) {
      const usable = deployerBal > reserveGas ? deployerBal - reserveGas : 0n;
      const fairShare = parseFloat(formatEther(usable)) / remaining;
      // 给个能装下当前余额的 [min, max] 建议（min = fairShare * 0.3，max = fairShare * 0.7
      // 留 30% 安全裕度防 random 抽飞）
      const sMax = Math.max(0.01, fairShare * 0.7);
      const sMin = Math.max(0.005, sMax * 0.3);
      console.error('');
      console.error(`❌ Deployer 余额不够把 ${remaining} 个钱包按当前 FUND_MIN/FUND_MAX 全部激活`);
      console.error(`   需要至少 ${formatEther(minNeed)} MAN（${remaining} × FUND_MIN=${cfg.fundMin} + gas 余量）`);
      console.error(`   实际余额 ${formatEther(deployerBal)} MAN，差 ${formatEther(minNeed - deployerBal)} MAN`);
      console.error('');
      console.error('   推荐方案 A：按 deployer 实际余额均分（每钱包 ~%s MAN）', fairShare.toFixed(4));
      console.error(`     FUND_MIN=${sMin.toFixed(4)} FUND_MAX=${sMax.toFixed(4)} make bot-grow-up`);
      console.error('');
      console.error('   方案 B：缩小目标钱包数');
      const safeTarget = Math.max(1, Math.floor(parseFloat(formatEther(deployerBal)) / cfg.fundMin / 1.5));
      console.error(`     GROWTH_TARGET=${safeTarget} make bot-grow-up`);
      console.error('');
      console.error('   方案 C：升级 deployer 创世余额（重建链，正经做法）');
      console.error('');
      console.error('   想强行跑（激活到没钱为止然后停，剩下的钱包不会被激活）：');
      console.error('     FORCE_GROW=1 make bot-grow-up');
      process.exit(1);
    }
  }

  const stats = { ok: 0, fail: 0, activated: 0, activateFail: 0, started: Date.now() };
  let bankrupt = false;          // 标记 deployer 已破产，不再尝试激活
  let bankruptAnnounced = false; // 只打印一次破产通知

  function announceBankrupt() {
    if (bankruptAnnounced) return;
    bankruptAnnounced = true;
    console.log('');
    console.log(`⚠️  Deployer 余额耗尽（剩 ${formatEther(deployerBal)} MAN），停止激活新钱包；`);
    console.log(`   已激活的 ${activeAccounts.length} 个钱包继续互转`);
  }

  // ---- 激活一个钱包（deployer → 新地址）----
  // 关键改动 vs 之前版本：
  //   1. 用本地缓存 deployerBal，每次成功扣账（amount + gas），失败不扣
  //   2. 抽 amount 时按当前余额 cap：amount ∈ [FUND_MIN, min(FUND_MAX, balance - gas)]
  //   3. 余额低于 FUND_MIN + gas 时直接 bankrupt，不再撞 RPC
  async function activateOne() {
    if (bankrupt) return false;
    if (!inactive.length) return false;
    const gasFee = 21000n * cfg.gasPrice;
    const minSend = parseEther(cfg.fundMin.toString());
    if (deployerBal < minSend + gasFee) {
      bankrupt = true;
      announceBankrupt();
      return false;
    }
    const usable = deployerBal - gasFee;
    const cap = Math.min(cfg.fundMax, parseFloat(formatEther(usable)));
    const amount = parseEther(rndFloat(cfg.fundMin, cap).toFixed(6));
    const idx = Math.floor(Math.random() * inactive.length);
    const w = inactive.splice(idx, 1)[0];
    const acc = privateKeyToAccount(w.privateKey);
    const nonce = deployerNonce++;
    try {
      await wc.sendTransaction({
        to: w.address,
        value: amount,
        nonce,
        gas: 21000n,
        maxFeePerGas: MAX_FEE_PER_GAS,
        maxPriorityFeePerGas: MAX_PRIORITY_FEE_PER_GAS,
      });
      deployerBal -= amount + gasFee;
      state.set(w.address, { account: acc, nonce: 0, balance: amount });
      activeAccounts.push(acc);
      activeAddrs.add(w.address);
      activeState.activated.push({ address: w.address, at: Date.now() });
      stats.activated++;
      return true;
    } catch (err) {
      stats.activateFail++;
      deployerNonce = nonce;
      inactive.push(w);
      // nonce / 余额可能跟实际不一致，重新同步
      try {
        [deployerNonce, deployerBal] = await Promise.all([
          publicClient.getTransactionCount({ address: deployer.address }),
          publicClient.getBalance({ address: deployer.address }),
        ]);
      } catch {}
      return false;
    }
  }

  // ---- bootstrap：让初始池立刻有人，否则前几秒 spam 没法跑 ----
  if (activeAccounts.length < cfg.growthInitial && inactive.length > 0) {
    const need = Math.min(cfg.growthInitial - activeAccounts.length, inactive.length);
    console.log(`==> Bootstrap：尝试激活 ${need} 个种子钱包...`);
    let succ = 0, fail = 0;
    for (let i = 0; i < need; i++) {
      const ok = await activateOne();
      if (ok) succ++; else fail++;
      process.stdout.write(`\r    成功 ${succ} / 失败 ${fail} / 进度 ${i + 1}/${need}`);
      if (bankrupt) break;
    }
    console.log('');
    saveActive();
    if (succ < 2) {
      console.error('');
      console.error(`❌ Bootstrap 完成但只激活了 ${succ} 个钱包，无法做有意义的互转`);
      console.error(`   建议：FUND_MIN/FUND_MAX 调小（当前 ${cfg.fundMin}-${cfg.fundMax}），`);
      console.error(`        或 GROWTH_INITIAL 调小（当前 ${cfg.growthInitial}）`);
      process.exit(1);
    }
  }

  console.log('');
  console.log(`==> 开始 grow（Ctrl+C 优雅退出，状态会存回 ${path.basename(cfg.activeFile)}）`);
  console.log('');

  // ---- 激活循环：200ms tick，按 burst 概率激活 ----
  const growHandle = setInterval(async () => {
    if (bankrupt) return;
    const elapsed = (Date.now() - activeState.startedAt) / 1000;
    const target = targetActiveAt(elapsed);
    const gap = target - activeAccounts.length;
    if (gap <= 0) return;
    if (Math.random() > cfg.growthBurstProb) return;
    // 单 burst 激活 1 ~ min(BURST_MAX, gap) 个；gap 越大越倾向激活更多
    const cap = Math.min(cfg.growthBurstMax, gap, inactive.length);
    if (cap <= 0) return;
    const n = rndInt(1, cap);
    for (let i = 0; i < n; i++) {
      await activateOne();
      if (bankrupt) break;
    }
    saveActive();
  }, 200);

  // ---- spam 循环：1s tick，发起数随激活池 ramp ----
  // effective_max = clamp(active * 0.3, [SPAM_MIN, SPAM_MAX])
  // 30 active → ~9，5642 active → 满 15
  const spamHandle = setInterval(() => {
    if (activeAccounts.length < 2) return;
    const dynMax = Math.max(
      cfg.spamMin,
      Math.min(cfg.spamMax, Math.floor(activeAccounts.length * 0.3))
    );
    const dynMin = Math.max(1, Math.min(cfg.spamMin, Math.floor(dynMax / 3)));
    const n = rndInt(dynMin, dynMax);
    const senders = pickRandomDistinct(activeAccounts, Math.min(n, activeAccounts.length));
    senders.forEach(s => spamSendOne(s, state, activeAccounts, stats));
  }, 1000);

  // ---- 状态行 ----
  const statHandle = setInterval(() => {
    const elapsed = (Date.now() - stats.started) / 1000;
    const target = targetActiveAt((Date.now() - activeState.startedAt) / 1000);
    const tps = stats.ok / elapsed;
    const tag = bankrupt ? ' [bankrupt]' : '';
    process.stdout.write(
      `\r[${elapsed.toFixed(0)}s]${tag} active=${activeAccounts.length}/${target} ` +
      `tx ok=${stats.ok} fail=${stats.fail} tps=${tps.toFixed(2)} ` +
      `new=${stats.activated} (fail=${stats.activateFail}) ` +
      `dep=${parseFloat(formatEther(deployerBal)).toFixed(2)}    `
    );
  }, 2000);

  // ---- 周期性持久化（防 SIGKILL 丢状态）----
  const persistHandle = setInterval(() => saveActive(), 30_000);

  const onShutdown = (sig) => {
    clearInterval(growHandle);
    clearInterval(spamHandle);
    clearInterval(statHandle);
    clearInterval(persistHandle);
    saveActive();
    const dt = ((Date.now() - stats.started) / 1000).toFixed(1);
    console.log('');
    console.log(`==> 收到 ${sig}，停止`);
    console.log(`    本轮运行 ${dt}s，新激活 ${stats.activated}（失败 ${stats.activateFail}），互转 ok=${stats.ok} fail=${stats.fail}`);
    console.log(`    active.json 已保存，下次 grow 会从这里续跑`);
    process.exit(0);
  };
  process.on('SIGINT', () => onShutdown('SIGINT'));
  process.on('SIGTERM', () => onShutdown('SIGTERM'));
}

// -----------------------------------------------------------------------------
// status: 看链 / 钱包状态
// -----------------------------------------------------------------------------
async function cmdStatus() {
  const wallets = loadWallets();
  console.log(`钱包文件     ${cfg.walletsFile}`);
  console.log(`钱包数量     ${wallets.length} / 目标 ${cfg.walletCount}`);
  if (fs.existsSync(cfg.activeFile)) {
    try {
      const a = JSON.parse(fs.readFileSync(cfg.activeFile, 'utf8'));
      const elapsed = (Date.now() - a.startedAt) / 1000;
      const target = targetActiveAt(elapsed);
      console.log(`Grow 进度    已激活 ${a.activated.length} / 目标 ${target}（曲线 ${cfg.growthCurve}，已跑 ${(elapsed / 3600).toFixed(2)}h / ${(cfg.growthDuration / 3600).toFixed(1)}h）`);
    } catch {}
  }
  try {
    const blockNumber = await publicClient.getBlockNumber();
    const realChainId = await publicClient.getChainId();
    console.log(`链 ID        ${realChainId}（期望 ${cfg.chainId}）`);
    console.log(`当前块号     ${blockNumber}`);
  } catch (err) {
    console.error(`❌ RPC 连不上 ${cfg.rpcUrl}：${err.shortMessage || err.message}`);
    process.exit(1);
  }
  if (cfg.deployerKey) {
    const dep = privateKeyToAccount(cfg.deployerKey);
    const bal = await publicClient.getBalance({ address: dep.address });
    console.log(`Deployer     ${dep.address}`);
    console.log(`             ${formatEther(bal)} MAN`);
  }
  if (wallets.length) {
    console.log(`抽样钱包余额（5 个，随机）：`);
    const sample = pickRandomDistinct(wallets, Math.min(5, wallets.length));
    for (const w of sample) {
      const bal = await publicClient.getBalance({ address: w.address });
      console.log(`  ${w.address}  ${formatEther(bal)} MAN`);
    }
  }
}

// -----------------------------------------------------------------------------
// consolidate: 把 sequencer/batcher/proposer/challenger 的余额合并到 deployer
//
// dev 链 genesis 给这 5 个 anvil 账户各预 mint 了 10000 MAN。除了 deployer 自己
// 用得上，另外 4 个账户的钱平时是闲着的（sequencer 等只发交易消耗少量 gas）。
// 这个命令把他们 4 个账户里 > 10 MAN 的部分全转给 deployer，瞬间多 ~40000 MAN。
//
// 不会动 sequencer/batcher/proposer/challenger 的运行：每个保留 10 MAN gas 应付
// 后续 op-batcher / op-proposer 等正常工作。
//
// 私钥来源：dev/.env 里的 SEQUENCER_PRIVATE_KEY / BATCHER_PRIVATE_KEY 等。
// 适合场景：不想重建链，又想 grow 跑出更大规模的演示。
// -----------------------------------------------------------------------------
async function cmdConsolidate() {
  if (!cfg.deployerKey) {
    console.error('❌ 缺 DEPLOYER_PRIVATE_KEY');
    process.exit(1);
  }
  const deployer = privateKeyToAccount(cfg.deployerKey);
  const reserve = parseEther(process.env.CONSOLIDATE_RESERVE || '10');
  const gasFee = 21000n * cfg.gasPrice;

  const sources = [
    ['SEQUENCER',  process.env.SEQUENCER_PRIVATE_KEY],
    ['BATCHER',    process.env.BATCHER_PRIVATE_KEY],
    ['PROPOSER',   process.env.PROPOSER_PRIVATE_KEY],
    ['CHALLENGER', process.env.CHALLENGER_PRIVATE_KEY],
  ].filter(([, k]) => k && k.length === 66);

  if (!sources.length) {
    console.error('❌ .env 里没找到 SEQUENCER/BATCHER/PROPOSER/CHALLENGER 私钥');
    process.exit(1);
  }

  const depBefore = await publicClient.getBalance({ address: deployer.address });
  console.log(`==> 归并目标 Deployer ${deployer.address}`);
  console.log(`    当前余额 ${formatEther(depBefore)} MAN`);
  console.log(`    每个源账户保留 ${formatEther(reserve)} MAN gas，其余全部转出`);
  console.log('');

  let totalMoved = 0n;
  for (const [name, pk] of sources) {
    const acc = privateKeyToAccount(pk);
    const bal = await publicClient.getBalance({ address: acc.address });
    if (bal <= reserve + gasFee) {
      console.log(`  ${name.padEnd(11)} ${acc.address}  余额 ${formatEther(bal)} MAN  (≤ reserve，跳过)`);
      continue;
    }
    const amount = bal - reserve - gasFee;
    const wc = createWalletClient({ account: acc, chain, transport: http(cfg.rpcUrl) });
    try {
      const hash = await wc.sendTransaction({
        to: deployer.address,
        value: amount,
        gas: 21000n,
        maxFeePerGas: MAX_FEE_PER_GAS,
        maxPriorityFeePerGas: MAX_PRIORITY_FEE_PER_GAS,
      });
      // 等 1 个块确认
      await publicClient.waitForTransactionReceipt({ hash, timeout: 60000 });
      totalMoved += amount;
      console.log(`  ${name.padEnd(11)} ${acc.address}  → 转出 ${formatEther(amount)} MAN  ✅`);
    } catch (err) {
      console.error(`  ${name.padEnd(11)} ${acc.address}  ❌ ${err.shortMessage || err.message}`);
    }
  }

  const depAfter = await publicClient.getBalance({ address: deployer.address });
  console.log('');
  console.log(`✅ 归并完成，共转入 ${formatEther(totalMoved)} MAN`);
  console.log(`   Deployer 余额：${formatEther(depBefore)} → ${formatEther(depAfter)} MAN`);
}

// -----------------------------------------------------------------------------
// mint: 通过 LiquidityController 从 NAL 池"增发" MAN 到指定地址
//
// 用法：node spammer.js mint [amount_in_MAN] [to_address]
//   默认 amount = 100000 MAN，to = deployer
//
// 原理（CGT v2 官方机制）：
//   genesis 在 NativeAssetLiquidity (0x4200..0029) 预存了 2e9 MAN 流动性池。
//   LiquidityController (0x4200..002A) 由 OWNER_MULTISIG 控制（dev 下 = deployer），
//   owner 可以 authorizeMinter(addr)，被授权的 minter 调 mint(to, amount) 就能从
//   NAL 池里把 MAN 划拨给 to。这是官方"增发"路径，没有重建链、没有改 state。
//
// 流程（首次自动一次性授权 deployer 当 minter）：
//   1. 检查 LiquidityController.owner() == deployer，否则报错（dev 默认相等）
//   2. 检查 isAuthorizedMinter(deployer)，没授权就 authorizeMinter(deployer)
//   3. mint(to, amount)
//
// 重复跑只会跳过授权步骤直接 mint。
// -----------------------------------------------------------------------------
// 全小写：避免 viem 严格 EIP-55 checksum 校验。这两个 predeploy 都是 v6.0.0 标准地址。
const LC_ADDR  = '0x420000000000000000000000000000000000002a';
const NAL_ADDR = '0x4200000000000000000000000000000000000029';
const LC_ABI = [
  { type: 'function', name: 'owner',              stateMutability: 'view',       inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'isAuthorizedMinter', stateMutability: 'view',       inputs: [{ name: 'minter', type: 'address' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'authorizeMinter',    stateMutability: 'nonpayable', inputs: [{ name: 'minter', type: 'address' }], outputs: [] },
  { type: 'function', name: 'mint',               stateMutability: 'nonpayable', inputs: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [] },
];

async function lcRead(name, args = []) {
  const data = encodeFunctionData({ abi: LC_ABI, functionName: name, args });
  const r = await publicClient.call({ to: LC_ADDR, data });
  return decodeFunctionResult({ abi: LC_ABI, functionName: name, data: r.data || '0x' });
}

// 把 viem 抛出的复杂错误对象拍扁成可读字符串，包含 revert reason / data / selector
function explainErr(err) {
  const parts = [];
  if (err.shortMessage) parts.push(err.shortMessage);
  if (err.metaMessages) parts.push(...err.metaMessages);
  if (err.cause) {
    if (err.cause.reason) parts.push(`reason="${err.cause.reason}"`);
    if (err.cause.data) parts.push(`raw_data=${err.cause.data}`);
    if (err.cause.shortMessage && !parts.includes(err.cause.shortMessage)) {
      parts.push(err.cause.shortMessage);
    }
  }
  if (err.data) parts.push(`data=${err.data}`);
  if (!parts.length) parts.push(err.message || String(err));
  return parts.filter(Boolean).join(' | ');
}

// clear-mempool: 把 deployer 卡 mempool 的所有 pending tx 用 0 wei 自转 + 极高 fee 顶替。
// op-geth 看到同 nonce 但 maxFeePerGas / maxPriorityFeePerGas 都高出 ≥10% 的新 tx 会
// 把旧 tx 替换出去。这里用 200 gwei / 100 gwei 远超任何之前 tx，肯定能顶。
async function cmdClearMempool() {
  if (!cfg.deployerKey) { console.error('❌ 缺 DEPLOYER_PRIVATE_KEY'); process.exit(1); }
  const dep = privateKeyToAccount(cfg.deployerKey);
  const wc = createWalletClient({ account: dep, chain, transport: http(cfg.rpcUrl) });

  const [latest, pending] = await Promise.all([
    publicClient.getTransactionCount({ address: dep.address, blockTag: 'latest' }),
    publicClient.getTransactionCount({ address: dep.address, blockTag: 'pending' }),
  ]);
  console.log(`Deployer ${dep.address}`);
  console.log(`  nonce  latest=${latest}  pending=${pending}`);
  if (pending <= latest) {
    console.log('  ✅ mempool 已干净，无需清理');
    return;
  }
  const stuck = pending - latest;
  console.log(`  ⚠️  ${stuck} 笔卡 mempool（nonce ${latest} - ${pending - 1}），逐个用高 fee 替换...`);
  console.log('');

  const HIGH_PRIORITY = parseGwei('100');
  const HIGH_MAX      = parseGwei('200');
  let succ = 0, fail = 0;
  for (let n = latest; n < pending; n++) {
    try {
      const hash = await wc.sendTransaction({
        to: dep.address,
        value: 0n,
        nonce: n,
        gas: 21000n,
        maxFeePerGas: HIGH_MAX,
        maxPriorityFeePerGas: HIGH_PRIORITY,
      });
      const r = await publicClient.waitForTransactionReceipt({ hash, timeout: 60000 });
      if (r.status === 'success') {
        succ++;
        console.log(`  nonce=${n} ✅ replace+confirm  block=${r.blockNumber}  tx=${hash}`);
      } else {
        fail++;
        console.log(`  nonce=${n} ❌ replace tx revert  tx=${hash}`);
      }
    } catch (e) {
      fail++;
      console.log(`  nonce=${n} ❌ ${e.shortMessage || e.message}`);
    }
  }
  console.log('');
  const [latest2, pending2] = await Promise.all([
    publicClient.getTransactionCount({ address: dep.address, blockTag: 'latest' }),
    publicClient.getTransactionCount({ address: dep.address, blockTag: 'pending' }),
  ]);
  console.log(`==> 清理完成：成功 ${succ} / 失败 ${fail}，最终 latest=${latest2} pending=${pending2}`);
}

// ping-tx: 用 deployer 发一笔 1 wei 自转 + 等待确认。专门用来确认链是不是真的在收 + 出块
async function cmdPingTx() {
  if (!cfg.deployerKey) {
    console.error('❌ 缺 DEPLOYER_PRIVATE_KEY');
    process.exit(1);
  }
  const dep = privateKeyToAccount(cfg.deployerKey);
  const wc = createWalletClient({ account: dep, chain, transport: http(cfg.rpcUrl) });

  const [head1, nL, nP, bal, latestBlock] = await Promise.all([
    publicClient.getBlockNumber(),
    publicClient.getTransactionCount({ address: dep.address, blockTag: 'latest' }),
    publicClient.getTransactionCount({ address: dep.address, blockTag: 'pending' }),
    publicClient.getBalance({ address: dep.address }),
    publicClient.getBlock({ blockTag: 'latest' }),
  ]);
  const baseFee = latestBlock.baseFeePerGas;
  console.log(`Deployer ${dep.address}`);
  console.log(`  balance ${formatEther(bal)} MAN`);
  console.log(`  nonce   latest=${nL}  pending=${nP}`);
  console.log(`  head    ${head1}`);
  console.log(`  base fee ${baseFee ? (Number(baseFee) / 1e9).toFixed(4) + ' gwei' : 'n/a'}`);
  if (nP > nL) {
    console.log(`  ⚠️  pending > latest（${nP - nL} 笔卡 mempool）— 用 docker compose restart op-geth 清掉再跑`);
  }
  console.log('');

  console.log('==> [1] 发 1 wei 自转（EIP-1559）...');
  const hash1559 = await send1559(wc, dep.address, undefined, 1n, 21000n);
  console.log(`    tx=${hash1559}`);
  try {
    const r = await publicClient.waitForTransactionReceipt({ hash: hash1559, timeout: 60000 });
    console.log(`    ✅ 确认  block=${r.blockNumber}  status=${r.status}  gasUsed=${r.gasUsed}`);
  } catch (e) {
    console.log(`    ❌ 60s 没确认：${e.shortMessage || e.message}`);
    console.log(`    用 docker exec mychain-op-geth geth --datadir=... attach 进 op-geth 看 mempool`);
  }
  console.log('');

  // 注意：故意不再发 legacy 测试 tx — 实测这条链拒收 zero-tip legacy，发了会卡 mempool
  // 占住 nonce 拖累后续。如果想复现，改 PING_LEGACY=1 环境变量启用。
  if (process.env.PING_LEGACY === '1') {
    console.log('==> [2] 发 1 wei 自转（legacy gasPrice，会占 nonce 卡 mempool）...');
    try {
      const hashLegacy = await wc.sendTransaction({
        to: dep.address, value: 1n, gas: 21000n, gasPrice: parseGwei('1'),
      });
      console.log(`    tx=${hashLegacy}`);
      const r = await publicClient.waitForTransactionReceipt({ hash: hashLegacy, timeout: 30000 });
      console.log(`    ✅ 确认  block=${r.blockNumber}  status=${r.status}`);
    } catch (e) {
      console.log(`    ❌ ${e.shortMessage || e.message}（这就是为啥 grow 必须用 1559）`);
    }
    console.log('');
  }

  const head2 = await publicClient.getBlockNumber();
  console.log(`==> 链 head 增长：${head1} → ${head2}（${head2 - head1} 个块）`);
  if (head2 === head1) {
    console.log(`   ⚠️  ping 期间链没出块，sequencer 可能死了 — 看 docker compose ps op-node 状态`);
  }
}

// inspect: 纯 view，打印 LC / NAL 当前状态，方便排查 mint revert
async function cmdInspectLc() {
  console.log(`==> LiquidityController @ ${LC_ADDR}`);
  console.log(`==> NativeAssetLiquidity @ ${NAL_ADDR}`);
  console.log('');

  const code = await publicClient.getCode({ address: LC_ADDR });
  console.log(`LC code length        ${code ? (code.length - 2) / 2 : 0} bytes`);
  const nalBal = await publicClient.getBalance({ address: NAL_ADDR });
  console.log(`NAL pool balance      ${formatEther(nalBal)} MAN`);

  try {
    const owner = await lcRead('owner');
    console.log(`LC.owner()            ${owner}`);
  } catch (e) {
    console.log(`LC.owner()            ❌ ${explainErr(e)}`);
  }

  if (cfg.deployerKey) {
    const dep = privateKeyToAccount(cfg.deployerKey);
    console.log(`Deployer              ${dep.address}`);
    try {
      const isMinter = await lcRead('isAuthorizedMinter', [dep.address]);
      console.log(`LC.isAuthorizedMinter(deployer)  ${isMinter}`);
    } catch (e) {
      console.log(`LC.isAuthorizedMinter(deployer)  ❌ ${explainErr(e)}`);
    }

    // 尝试模拟 authorizeMinter，提取 revert reason
    console.log('');
    console.log('==> Simulate authorizeMinter(deployer) ...');
    try {
      await publicClient.call({
        account: dep,
        to: LC_ADDR,
        data: encodeFunctionData({ abi: LC_ABI, functionName: 'authorizeMinter', args: [dep.address] }),
      });
      console.log('   ✅ simulate ok（实际 send 应该会成功）');
    } catch (e) {
      console.log('   ❌ ' + explainErr(e));
    }

    console.log('');
    console.log('==> Simulate mint(deployer, 1 MAN) — 注意：未真正 authorize 时 mint 会 revert');
    try {
      await publicClient.call({
        account: dep,
        to: LC_ADDR,
        data: encodeFunctionData({ abi: LC_ABI, functionName: 'mint', args: [dep.address, parseEther('1')] }),
      });
      console.log('   ✅ simulate ok（说明 deployer 已经被授权过 / 或合约不需要授权）');
    } catch (e) {
      console.log('   ❌ ' + explainErr(e));
      console.log('   ↑ 大概率是因为还没真的 send authorizeMinter tx；跑 `make bot-mint AMOUNT=1` 走完整流程');
    }
  }
}

// 必须用 EIP-1559：实测这条链的 op-geth 拒收零 priority fee 的 legacy tx
// （legacy tx 进 mempool 但永远不上链，占着 nonce 卡死后续 tx）。
//
// 策略：固定高 maxFeePerGas（远超动态 base fee），op-geth 实际只扣 baseFee + tip。
// 这两个常量也被 grow/spam 高频路径用，避免每笔查 base fee。
const MAX_FEE_PER_GAS      = parseGwei(process.env.MAX_FEE_GWEI || '50');
const MAX_PRIORITY_FEE_PER_GAS = parseGwei(process.env.PRIORITY_FEE_GWEI || '1');

async function send1559(wc, to, data, value, gas, nonce) {
  // 显式传 nonce 避免 viem 默认 latest 跟 mempool 残留撞
  return wc.sendTransaction({
    to,
    data,
    value,
    gas,
    nonce,
    maxFeePerGas: MAX_FEE_PER_GAS,
    maxPriorityFeePerGas: MAX_PRIORITY_FEE_PER_GAS,
  });
}

async function cmdMint() {
  if (!cfg.deployerKey) {
    console.error('❌ 缺 DEPLOYER_PRIVATE_KEY');
    process.exit(1);
  }
  const deployer = privateKeyToAccount(cfg.deployerKey);
  const amountStr = process.argv[3] || '100000';
  const toAddr = (process.argv[4] || deployer.address).toLowerCase();
  const amount = parseEther(amountStr);

  console.log(`==> Mint MAN via LiquidityController`);
  console.log(`    Caller (=owner)  ${deployer.address}`);
  console.log(`    To               ${toAddr}`);
  console.log(`    Amount           ${amountStr} MAN (${amount} wei)`);
  console.log('');

  // 诊断：当前 chain head + deployer nonce
  const [head, nonceLatest, noncePending] = await Promise.all([
    publicClient.getBlockNumber(),
    publicClient.getTransactionCount({ address: deployer.address, blockTag: 'latest' }),
    publicClient.getTransactionCount({ address: deployer.address, blockTag: 'pending' }),
  ]);
  console.log(`    Chain head       ${head}`);
  console.log(`    Deployer nonce   latest=${nonceLatest}  pending=${noncePending}`);
  if (noncePending > nonceLatest) {
    console.error(`    ❌ pending > latest（${noncePending - nonceLatest} 笔卡 mempool）`);
    console.error(`       新 tx 用 nonce=${noncePending} 会排在卡死 tx 后面，永远等不到`);
    console.error(`       先跑 \`make bot-clear-mempool\` 把它们顶掉，再重试 mint`);
    process.exit(1);
  }
  console.log('');

  // 1. NAL 池余额
  const nalBal = await publicClient.getBalance({ address: NAL_ADDR });
  console.log(`    NAL 池余额       ${formatEther(nalBal)} MAN`);
  if (nalBal < amount) {
    console.error(`❌ NAL 池余额不够，无法 mint ${amountStr} MAN`);
    process.exit(1);
  }

  // 2. 验证 owner
  const owner = await lcRead('owner');
  if (owner.toLowerCase() !== deployer.address.toLowerCase()) {
    console.error(`❌ LiquidityController.owner() = ${owner}`);
    console.error(`   Deployer ${deployer.address} 不是 owner，无法 authorizeMinter`);
    console.error(`   要么用 owner 私钥跑此命令；dev 环境默认 OWNER_MULTISIG=DEPLOYER_ADDRESS，`);
    console.error(`   不一致说明 .env 被改过`);
    process.exit(1);
  }
  console.log(`    ✅ deployer 是 LiquidityController owner`);

  const wc = createWalletClient({ account: deployer, chain, transport: http(cfg.rpcUrl) });

  // 3. 授权 deployer 当 minter
  // 注意：实测 isAuthorizedMinter(address) 这个 view 在 OP Stack v6 实际部署的 LC 上 revert（函数
  // 签名/名字跟 spec 文档不一致），所以不依赖它判断。直接 simulate authorizeMinter 看会不会成功：
  //   - simulate 成功且 deployer 还没授权 → 走真实 send
  //   - simulate revert 且原因是 "AlreadyAuthorized" / 之类 → 跳过授权直接 mint
  //   - simulate revert 且其他原因 → 报错退出
  const authData = encodeFunctionData({ abi: LC_ABI, functionName: 'authorizeMinter', args: [deployer.address] });
  let needAuthorize = true;
  try {
    await publicClient.call({ account: deployer, to: LC_ADDR, data: authData });
  } catch (e) {
    const msg = explainErr(e).toLowerCase();
    if (msg.includes('already') || msg.includes('authorized')) {
      console.log(`    ✅ deployer 已是 authorized minter（跳过授权）`);
      needAuthorize = false;
    } else {
      console.error('❌ authorizeMinter simulate 失败：' + explainErr(e));
      console.error('   跑 `make bot-inspect-lc` 看更多信息');
      process.exit(1);
    }
  }
  // 用 pending nonce，所以新 tx 紧接着 mempool 里最后一笔（这里 mempool 已确认空）
  let nextNonce = noncePending;

  if (needAuthorize) {
    console.log(`    Deployer 还不是 authorized minter，发 authorizeMinter tx（nonce=${nextNonce}）...`);
    const hash = await send1559(wc, LC_ADDR, authData, undefined, 200000n, nextNonce);
    console.log(`    tx=${hash}（等 120s 进块）`);
    const r = await publicClient.waitForTransactionReceipt({ hash, timeout: 120000 });
    if (r.status !== 'success') {
      console.error(`❌ authorizeMinter on-chain revert  tx=${hash}  block=${r.blockNumber}`);
      process.exit(1);
    }
    console.log(`    ✅ authorizeMinter ok  block=${r.blockNumber}`);
    nextNonce++;
  }

  // 4. mint
  const balBefore = await publicClient.getBalance({ address: toAddr });
  const data = encodeFunctionData({ abi: LC_ABI, functionName: 'mint', args: [toAddr, amount] });
  try {
    await publicClient.call({ account: deployer, to: LC_ADDR, data });
  } catch (e) {
    console.error('❌ mint simulate 失败：' + explainErr(e));
    console.error('   跑 `make bot-inspect-lc` 看更多信息');
    process.exit(1);
  }
  console.log(`    发 mint tx（nonce=${nextNonce}）...`);
  const hash = await send1559(wc, LC_ADDR, data, undefined, 300000n, nextNonce);
  console.log(`    mint tx=${hash}（等 120s 进块）`);
  const r = await publicClient.waitForTransactionReceipt({ hash, timeout: 120000 });
  if (r.status !== 'success') {
    console.error(`❌ mint on-chain revert  tx=${hash}  block=${r.blockNumber}`);
    process.exit(1);
  }
  const balAfter = await publicClient.getBalance({ address: toAddr });
  const nalAfter = await publicClient.getBalance({ address: NAL_ADDR });
  console.log('');
  console.log(`✅ mint ok  tx=${hash}`);
  console.log(`   ${toAddr} 余额：${formatEther(balBefore)} → ${formatEther(balAfter)} MAN`);
  console.log(`   NAL 池余额：${formatEther(nalAfter)} MAN`);
}

// -----------------------------------------------------------------------------
// main
// -----------------------------------------------------------------------------
const cmd = process.argv[2];
const handlers = {
  init: cmdInit,
  grow: cmdGrow,
  fund: cmdFund,
  spam: cmdSpam,
  status: cmdStatus,
  consolidate: cmdConsolidate,
  mint: cmdMint,
  'inspect-lc': cmdInspectLc,
  'ping-tx': cmdPingTx,
  'clear-mempool': cmdClearMempool,
};
const fn = handlers[cmd];
if (!fn) {
  console.error('用法: node spammer.js {init|grow|fund|spam|status|consolidate|mint}');
  console.error('');
  console.error('  init                          生成 5642 钱包到 wallets.json');
  console.error('  grow                          [拟真] 渐进式上线 + 同步互转，永久跑');
  console.error('  fund                          [一次性] 从 deployer 给所有钱包打钱');
  console.error('  spam                          [一次性] 每秒 3-15 笔随机互转');
  console.error('  status                        看链 / 钱包 / 激活进度');
  console.error('  consolidate                   把 sequencer/batcher/proposer/challenger 闲钱合并到 deployer');
  console.error('  mint [amount] [to]            通过 LiquidityController 从 NAL 池增发 MAN（默认 100000 给 deployer）');
  console.error('');
  console.error('推荐做 demo：npm run init && npm run mint && npm run grow');
  console.error('压测一波：  npm run init && npm run mint -- 30000000 && npm run fund && npm run spam');
  process.exit(1);
}
fn().catch(err => {
  console.error('\n❌ 错误：', err.shortMessage || err.message || err);
  if (process.env.DEBUG) console.error(err.stack || err);
  process.exit(1);
});
