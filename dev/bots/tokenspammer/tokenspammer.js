#!/usr/bin/env node
// =============================================================================
// MAN L2 ERC-20 多 token 压测机器人
//
// 目标场景：在 L2 上部署 1000 个 ERC-20，给 50000 个地址灌种子，然后
// 持续以 ~1000 TPS 在地址间随机互转这些 token。压测 sequencer / op-geth /
// blockscout 索引 / 监控全链路。
//
// 子命令（在 dev/bots/tokenspammer 目录下跑，或通过 make bot-token-* 调起）：
//   build       一次性，docker 里 forge 编译合约 → artifacts.json
//                  （脚本在 build.sh，不在这里）
//   init        生成 50000 个钱包到 wallets-50k.json（含私钥，已 gitignore）
//   mint        通过 LiquidityController 从 NAL 池增发 MAN 给 deployer
//                  默认 5000 MAN，足够 50k 钱包灌 gas + 1000 token 部署 + 长期 spam
//   fund-gas    给 50000 钱包各打 0.5 MAN 用作 gas（用 BatchTransfer 一次 200 个）
//   deploy      并发部署 1 个 BatchTransfer + 1000 个 TestERC20，写入 tokens.json
//                  deployer 持有每个 token 全部初始 supply (1e9 tokens)，并对
//                  BatchTransfer 授权 max
//   seed        每个 token 随机选 N (默认 500) 个钱包，用 BatchTransfer 一次发 200 个
//   spam        高吞吐随机互转：每 100ms tick pick 100 个 (token, holder) → 任意地址
//                  目标 TPS 由 TARGET_TPS 控制（默认 1000）
//   status      看 wallets / tokens / 链状态
//
// 环境变量（自动从 dev/.env 读，可显式覆盖）：
//   RPC_URL              默认 http://op-geth:8545（docker 内）/ http://localhost:9545
//                        所有"通用"调用走这个：链 metadata、deploy/mint/seed/fund-gas、status
//   SPAM_RPC_URL         默认 = RPC_URL。spam 子命令发 sendRawTransaction 用的端点。
//                        Flashblocks 部署后改成 op-rbuilder 的 RPC（真正出块的 sequencer
//                        EL，必须直接发到这里，否则 tx 进 op-geth mempool 但
//                        op-rbuilder 看不到，要等 mempool rebroadcaster 同步才行）
//   DIAG_RPC_URL         默认 = SPAM_RPC_URL。mempool 监控（backpressure）用的端点。
//                        必须看 sequencer EL 的真实 mempool —— 跟 SPAM_RPC_URL 同步
//   L2_CHAIN_ID          必需
//   DEPLOYER_PRIVATE_KEY 必需（mint / deploy / seed / fund-gas 都要）
//   WALLETS_FILE         默认 ./wallets-50k.json
//   TOKENS_FILE          默认 ./tokens.json
//   ARTIFACTS_DIR        默认 ./contracts/out（forge 产物目录）
//   WALLET_COUNT         默认 50000
//   TOKEN_COUNT          默认 1000
//   HOLDERS_PER_TOKEN    默认 500    （seed 阶段每个 token 分发给多少地址）
//   FUND_GAS_AMOUNT      默认 0.5    （MAN，每个钱包 gas 储备；0.5 MAN ≈ 10k 笔 ERC20）
//   FUND_BATCH_SIZE      默认 200    （batchSendNative 单笔多少接收人）
//   SEED_BATCH_SIZE      默认 200    （batchTransferFrom 单笔多少接收人）
//   SEED_AMOUNT          默认 1000000 （token，每个 holder 初始余额）
//   TOKEN_INITIAL_SUPPLY 默认 1000000000 （token，每个 token 总发行量）
//   SPAM_AMOUNT_WEI      默认 1e15   （每笔 spam transfer 的 token wei 数 = 0.001 token）
//   TARGET_TPS           默认 200    （实测链稳态 ~150 TPS = OP Stack op-geth 单线程
//                                     EVM + 1s block 的极限。设 200 = 链 1.3x 速度，
//                                     mempool 缓慢累积、backpressure 偶发但不雪崩，
//                                     长时间稳定运行验证链可靠性。设 300+ 会更频繁
//                                     触发 backpressure；设 1000+ 会让 mempool 雪崩）
//   SPAM_TICK_MS         默认 100    （多久触发一次 spam batch；100ms × 20 笔 = 200 TPS）
//   MAX_TICK_QUEUE       默认 8      （同时在路上的 RPC batch 数。300 TPS 节奏下 8 够用，
//                                     设大反而触发 op-geth txpool 锁竞争；想冲峰值改 16）
//   HTTP_CONNECTIONS     默认 64     （undici 全局连接池上限，绕过默认 10 conn 瓶颈）
//   MEMPOOL_BACKPRESSURE 默认 1      （1=开，0=关。开启时 spammer 会查 mempool，
//                                     防止 op-geth pending 涨到雪崩点）
//   MEMPOOL_HIGH_WATER   默认 3000   （pending+queued ≥ 此值时暂停发送。链 ~150 TPS,
//                                     3000 ≈ 20s buffer，给 sequencer 充足消化时间）
//   MEMPOOL_LOW_WATER    默认 1000   （pending+queued ≤ 此值时恢复发送）
//   MEMPOOL_CHECK_MS     默认 2000   （多久查一次 mempool）
//   GAS_PRICE_GWEI       默认 1
//   MAX_FEE_GWEI         默认 50
//   PRIORITY_FEE_GWEI    默认 1
//
// 注意：
//   - wallets-50k.json 含 50000 个明文私钥（约 9 MB），权限 0600，已 gitignore
//   - 仅 dev / 压测用，绝对不要 commit / 不要发外网 / 不要复用主网
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
  encodeDeployData,
} from 'viem';
import { privateKeyToAccount, privateKeyToAddress, generatePrivateKey } from 'viem/accounts';
import { Agent, setGlobalDispatcher } from 'undici';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// -----------------------------------------------------------------------------
// HTTP 连接池
// -----------------------------------------------------------------------------
// node 内置 fetch（undici）默认每个 origin 只开 ~10 个连接。
// 在 spam 场景下 10 个并发批次会把连接打满，sendRawTransaction 回包变成串行，
// 实测 200 TPS 卡上限。这里全局把连接数提到 64。
// pipelining=1（默认）就够了，HTTP/1.1 pipelining 在 op-geth 上没好处。
const HTTP_CONNECTIONS = parseInt(process.env.HTTP_CONNECTIONS || '64');
setGlobalDispatcher(new Agent({
  connections: HTTP_CONNECTIONS,
  pipelining: 1,
  keepAliveTimeout: 30_000,
  keepAliveMaxTimeout: 60_000,
  bodyTimeout: 60_000,
  headersTimeout: 60_000,
}));

// -----------------------------------------------------------------------------
// .env 加载
// -----------------------------------------------------------------------------
function loadEnvFile(envPath) {
  if (!fs.existsSync(envPath)) return;
  for (const raw of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const m = line.match(/^([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$/);
    if (!m) continue;
    if (process.env[m[1]] !== undefined) continue;
    let val = m[2].trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    process.env[m[1]] = val;
  }
}
loadEnvFile(path.resolve(__dirname, '../../.env'));

// -----------------------------------------------------------------------------
// 配置
// -----------------------------------------------------------------------------
const DEFAULT_RPC = `http://localhost:${process.env.L2_RPC_PORT || '9545'}`;
const cfg = {
  rpcUrl: process.env.RPC_URL || DEFAULT_RPC,
  // spam 子命令发 sendRawTransaction 的 RPC 端点。
  // 默认跟 rpcUrl 同一个；Flashblocks 部署后改成 op-rbuilder。
  spamRpcUrl: process.env.SPAM_RPC_URL || process.env.RPC_URL || DEFAULT_RPC,
  // mempool / 诊断 RPC 端点。监控的对象必须是"真正出块的 EL"。
  // 默认跟 spamRpcUrl 同一个。
  diagRpcUrl:
    process.env.DIAG_RPC_URL ||
    process.env.SPAM_RPC_URL ||
    process.env.RPC_URL ||
    DEFAULT_RPC,
  chainId: parseInt(process.env.L2_CHAIN_ID || '0'),
  deployerKey: process.env.DEPLOYER_PRIVATE_KEY,
  walletsFile: path.resolve(__dirname, process.env.WALLETS_FILE || 'wallets-50k.json'),
  tokensFile: path.resolve(__dirname, process.env.TOKENS_FILE || 'tokens.json'),
  // forge build 后产物在 contracts/out/<src>.sol/<contract>.json
  artifactsDir: path.resolve(__dirname, process.env.ARTIFACTS_DIR || 'contracts/out'),
  walletCount: parseInt(process.env.WALLET_COUNT || '50000'),
  tokenCount: parseInt(process.env.TOKEN_COUNT || '1000'),
  holdersPerToken: parseInt(process.env.HOLDERS_PER_TOKEN || '500'),
  fundGasAmount: parseFloat(process.env.FUND_GAS_AMOUNT || '0.5'),
  fundBatchSize: parseInt(process.env.FUND_BATCH_SIZE || '200'),
  seedBatchSize: parseInt(process.env.SEED_BATCH_SIZE || '200'),
  seedAmount: BigInt(process.env.SEED_AMOUNT || '1000000') * 10n ** 18n,
  tokenInitialSupply: BigInt(process.env.TOKEN_INITIAL_SUPPLY || '1000000000') * 10n ** 18n,
  spamAmountWei: BigInt(process.env.SPAM_AMOUNT_WEI || '1000000000000000'),
  // 实测当前链稳态 TPS ~150（OP Stack op-geth 单线程 + 1s block + 35k gas/transfer 极限）。
  // 默认 200 TPS = 链 1.3x，mempool 缓慢累积、偶发 backpressure 但不雪崩，
  // 长跑稳定。想冲极限：TARGET_TPS=1000 + MEMPOOL_BACKPRESSURE=0（仅短时观察）。
  targetTps: parseInt(process.env.TARGET_TPS || '200'),
  // tick=100ms / target=200 → 每 tick 20 笔。
  // 实测 op-geth 的 txpool.mu 是全局锁，并发太多小 batch 会把 RPC goroutine
  // 串行化反而慢。每批 20 笔 + 8 并发 batch（160 in-flight）刚好不撞锁。
  spamTickMs: parseInt(process.env.SPAM_TICK_MS || '100'),
  gasPrice: parseGwei(process.env.GAS_PRICE_GWEI || '1'),
};
const MAX_FEE_PER_GAS         = parseGwei(process.env.MAX_FEE_GWEI || '50');
const MAX_PRIORITY_FEE_PER_GAS = parseGwei(process.env.PRIORITY_FEE_GWEI || '1');

if (!cfg.chainId) {
  console.error('❌ 缺 L2_CHAIN_ID（在 dev/.env 里）');
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
function rndInt(min, max) { return min + Math.floor(Math.random() * (max - min + 1)); }
function loadWallets() {
  if (!fs.existsSync(cfg.walletsFile)) return [];
  return JSON.parse(fs.readFileSync(cfg.walletsFile, 'utf8'));
}
function saveWallets(wallets) {
  // 一行一个，~9MB 时仍可 grep
  const body = wallets.map(w => '  ' + JSON.stringify(w)).join(',\n');
  fs.writeFileSync(cfg.walletsFile, '[\n' + body + '\n]\n', { mode: 0o600 });
}
function loadTokens() {
  if (!fs.existsSync(cfg.tokensFile)) return null;
  return JSON.parse(fs.readFileSync(cfg.tokensFile, 'utf8'));
}
function saveTokens(state) {
  // tokens 是 token 数组，holders 用 wallet index 紧凑表示
  fs.writeFileSync(cfg.tokensFile, JSON.stringify(state, null, 2));
}
function loadArtifacts() {
  // 直接读 forge 产物，无中间步骤
  const erc20Path = path.join(cfg.artifactsDir, 'TestERC20.sol/TestERC20.json');
  const batchPath = path.join(cfg.artifactsDir, 'BatchTransfer.sol/BatchTransfer.json');
  if (!fs.existsSync(erc20Path) || !fs.existsSync(batchPath)) {
    console.error(`❌ 没找到 forge 产物，先 make bot-token-build`);
    console.error(`   期望: ${erc20Path}`);
    console.error(`         ${batchPath}`);
    process.exit(1);
  }
  const erc20Art = JSON.parse(fs.readFileSync(erc20Path, 'utf8'));
  const batchArt = JSON.parse(fs.readFileSync(batchPath, 'utf8'));
  return {
    TestERC20: { abi: erc20Art.abi, bytecode: erc20Art.bytecode.object },
    BatchTransfer: { abi: batchArt.abi, bytecode: batchArt.bytecode.object },
  };
}
function fmtNum(n) {
  return n.toLocaleString('en-US');
}
function explainErr(err) {
  return err.shortMessage || err.message || String(err);
}

// -----------------------------------------------------------------------------
// 原始 JSON-RPC 批量调用工具
//   - viem 默认走 fetch + undici keep-alive，但每个 call 一个 HTTP 请求
//   - 大批量场景（50k nonce 拉取 / 100-batch sendRawTx）必须用 JSON-RPC batch：
//     一个 HTTP 请求 N 个调用，复用同一个 socket，省 99% 的握手 / parse 开销
// -----------------------------------------------------------------------------
async function rpcBatch(methodAndParams, url = cfg.rpcUrl) {
  const reqs = methodAndParams.map(([method, params], i) => ({
    jsonrpc: '2.0', method, params, id: i,
  }));
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(reqs),
  });
  if (!res.ok) throw new Error(`RPC HTTP ${res.status}`);
  const arr = await res.json();
  // 防御：JSON-RPC spec 规定 batch 返回数组，但 op-geth 异常时可能返回单个 error 对象
  if (!Array.isArray(arr)) {
    throw new Error(`RPC batch returned non-array: ${JSON.stringify(arr).slice(0, 200)}`);
  }
  // 按 id 复原顺序（op-geth 通常按序返回，但 spec 不保证）
  const out = new Array(methodAndParams.length);
  for (const r of arr) out[r.id] = r;
  return out;
}

// -----------------------------------------------------------------------------
// 子命令: init  生成 50000 钱包
// -----------------------------------------------------------------------------
async function cmdInit() {
  let wallets = loadWallets();
  console.log(`==> 已有 ${fmtNum(wallets.length)} / 目标 ${fmtNum(cfg.walletCount)}`);
  if (wallets.length >= cfg.walletCount) {
    console.log('✅ 数量已达标，跳过生成');
    return;
  }
  const need = cfg.walletCount - wallets.length;
  console.log(`==> 生成 ${fmtNum(need)} 个新钱包...`);
  const t0 = Date.now();
  for (let i = 0; i < need; i++) {
    const pk = generatePrivateKey();
    // privateKeyToAddress 比 privateKeyToAccount 快约 5x（不构造完整 account 对象）
    const address = privateKeyToAddress(pk);
    wallets.push({ address, privateKey: pk });
    if ((i + 1) % 5000 === 0) {
      process.stdout.write(`\r    ${fmtNum(i + 1)}/${fmtNum(need)}  (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
    }
  }
  console.log('');
  console.log(`==> 写盘 ${cfg.walletsFile} (~${(JSON.stringify(wallets).length / 1024 / 1024).toFixed(1)} MB)`);
  saveWallets(wallets);
  console.log(`✅ 共 ${fmtNum(wallets.length)} 钱包，文件 mode 0600`);
  console.log(`   ⚠️  含 ${fmtNum(wallets.length)} 个明文私钥，绝对不要 commit / 发外网`);
}

// -----------------------------------------------------------------------------
// 子命令: mint  调 LiquidityController 从 NAL 池增发 MAN
// -----------------------------------------------------------------------------
const LC_ADDR  = '0x420000000000000000000000000000000000002a';
const NAL_ADDR = '0x4200000000000000000000000000000000000029';
const LC_ABI = [
  { type: 'function', name: 'owner',              stateMutability: 'view',       inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'authorizeMinter',    stateMutability: 'nonpayable', inputs: [{ name: 'minter', type: 'address' }], outputs: [] },
  { type: 'function', name: 'mint',               stateMutability: 'nonpayable', inputs: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [] },
];

async function cmdMint() {
  if (!cfg.deployerKey) { console.error('❌ 缺 DEPLOYER_PRIVATE_KEY'); process.exit(1); }
  const deployer = privateKeyToAccount(cfg.deployerKey);
  const amountStr = process.argv[3] || '5000';
  const amount = parseEther(amountStr);

  const wc = createWalletClient({ account: deployer, chain, transport: http(cfg.rpcUrl) });

  console.log(`==> 通过 LiquidityController 增发 ${amountStr} MAN → ${deployer.address}`);

  // 0. 先看 NAL 池余额够不够
  const nalBal = await publicClient.getBalance({ address: NAL_ADDR });
  console.log(`    NAL 池余额 ${formatEther(nalBal)} MAN`);
  if (nalBal < amount) {
    console.error(`❌ NAL 池不够 ${amountStr} MAN`);
    process.exit(1);
  }

  // 1. 检查 owner
  const ownerData = encodeFunctionData({ abi: LC_ABI, functionName: 'owner' });
  const ownerRes = await publicClient.call({ to: LC_ADDR, data: ownerData });
  const owner = decodeFunctionResult({ abi: LC_ABI, functionName: 'owner', data: ownerRes.data });
  if (owner.toLowerCase() !== deployer.address.toLowerCase()) {
    console.error(`❌ LC.owner = ${owner}，但 deployer = ${deployer.address}`);
    process.exit(1);
  }

  // 2. 试授权（已授权的话 simulate 会成功；上链一次 → 之后跳过）
  const authData = encodeFunctionData({ abi: LC_ABI, functionName: 'authorizeMinter', args: [deployer.address] });
  let nonce = await publicClient.getTransactionCount({ address: deployer.address });

  let needAuth = true;
  try {
    await publicClient.call({ account: deployer, to: LC_ADDR, data: authData });
  } catch (e) {
    const msg = explainErr(e).toLowerCase();
    if (msg.includes('already') || msg.includes('authorized')) {
      console.log(`    ✅ deployer 已是 authorized minter`);
      needAuth = false;
    } else {
      console.error(`❌ authorizeMinter simulate fail: ${explainErr(e)}`);
      process.exit(1);
    }
  }
  if (needAuth) {
    console.log(`    发 authorizeMinter (nonce=${nonce})...`);
    const h = await wc.sendTransaction({
      to: LC_ADDR, data: authData, gas: 200000n, nonce,
      maxFeePerGas: MAX_FEE_PER_GAS, maxPriorityFeePerGas: MAX_PRIORITY_FEE_PER_GAS,
    });
    const r = await publicClient.waitForTransactionReceipt({ hash: h, timeout: 120000 });
    if (r.status !== 'success') { console.error('❌ authorizeMinter on-chain revert'); process.exit(1); }
    console.log(`    ✅ block=${r.blockNumber}`);
    nonce++;
  }

  // 3. mint
  const mintData = encodeFunctionData({ abi: LC_ABI, functionName: 'mint', args: [deployer.address, amount] });
  console.log(`    发 mint (nonce=${nonce})...`);
  const balBefore = await publicClient.getBalance({ address: deployer.address });
  const h = await wc.sendTransaction({
    to: LC_ADDR, data: mintData, gas: 300000n, nonce,
    maxFeePerGas: MAX_FEE_PER_GAS, maxPriorityFeePerGas: MAX_PRIORITY_FEE_PER_GAS,
  });
  const r = await publicClient.waitForTransactionReceipt({ hash: h, timeout: 120000 });
  if (r.status !== 'success') { console.error('❌ mint on-chain revert'); process.exit(1); }
  const balAfter = await publicClient.getBalance({ address: deployer.address });
  console.log(`✅ mint ok  block=${r.blockNumber}`);
  console.log(`   deployer 余额 ${formatEther(balBefore)} → ${formatEther(balAfter)} MAN`);
}

// -----------------------------------------------------------------------------
// 共享：等所有 in-flight 顺序 nonce tx 中最后一个的 receipt
// -----------------------------------------------------------------------------
async function waitLast(hash, label = 'tx') {
  if (!hash) return;
  console.log(`==> 等最后一笔 ${label} receipt（${hash.slice(0, 18)}...）`);
  const r = await publicClient.waitForTransactionReceipt({ hash, timeout: 180000 });
  if (r.status !== 'success') {
    console.error(`❌ 最后一笔 ${label} on-chain revert`);
    process.exit(1);
  }
  console.log(`    ✅ block=${r.blockNumber}`);
}

// -----------------------------------------------------------------------------
// 子命令: deploy  并发部署 1 个 BatchTransfer + N 个 TestERC20，记 tokens.json
// -----------------------------------------------------------------------------
async function cmdDeploy() {
  if (!cfg.deployerKey) { console.error('❌ 缺 DEPLOYER_PRIVATE_KEY'); process.exit(1); }
  const deployer = privateKeyToAccount(cfg.deployerKey);
  const wc = createWalletClient({ account: deployer, chain, transport: http(cfg.rpcUrl) });
  const art = loadArtifacts();

  const wallets = loadWallets();
  if (wallets.length !== cfg.walletCount) {
    console.error(`❌ 钱包数 ${wallets.length} != 期望 ${cfg.walletCount}，先 make bot-token-init`);
    process.exit(1);
  }

  let state = loadTokens() || { batchTransfer: null, deployer: deployer.address, tokens: [] };
  if (state.deployer.toLowerCase() !== deployer.address.toLowerCase()) {
    console.error(`❌ tokens.json deployer=${state.deployer}，但当前 DEPLOYER=${deployer.address}`);
    console.error(`   要么用同一个 deployer，要么删 tokens.json 重新部署`);
    process.exit(1);
  }

  // 0. 余额预检查
  const bal = await publicClient.getBalance({ address: deployer.address });
  console.log(`==> Deployer ${deployer.address}`);
  console.log(`    余额 ${formatEther(bal)} MAN`);
  // 1000 deploy × 600k gas + BatchTransfer 800k × 1 gwei = ~0.6 MAN
  // 1000 token approve × 50k gas = 0.05 MAN
  const minNeed = parseEther('2');
  if (bal < minNeed) {
    console.error(`❌ deployer 余额 < 2 MAN，先 make bot-token-mint AMOUNT=5000`);
    process.exit(1);
  }

  let nonce = await publicClient.getTransactionCount({ address: deployer.address });
  console.log(`    起始 nonce ${nonce}`);
  console.log('');

  // 1. 部署 BatchTransfer（如果还没部署）
  if (!state.batchTransfer) {
    console.log('==> [1/3] 部署 BatchTransfer ...');
    const data = art.BatchTransfer.bytecode.startsWith('0x')
      ? art.BatchTransfer.bytecode
      : '0x' + art.BatchTransfer.bytecode;
    const h = await wc.sendTransaction({
      data,
      gas: 1500000n,
      nonce: nonce++,
      maxFeePerGas: MAX_FEE_PER_GAS,
      maxPriorityFeePerGas: MAX_PRIORITY_FEE_PER_GAS,
    });
    const r = await publicClient.waitForTransactionReceipt({ hash: h, timeout: 120000 });
    if (r.status !== 'success' || !r.contractAddress) {
      console.error('❌ BatchTransfer 部署失败');
      process.exit(1);
    }
    state.batchTransfer = r.contractAddress;
    saveTokens(state);
    console.log(`    ✅ BatchTransfer @ ${r.contractAddress}  (block ${r.blockNumber})`);
  } else {
    console.log(`==> [1/3] BatchTransfer 已部署 @ ${state.batchTransfer}（跳过）`);
  }

  // 2. 并发部署 N - 已部署数 个 TestERC20
  const erc20Abi = art.TestERC20.abi;
  const erc20Bytecode = art.TestERC20.bytecode.startsWith('0x')
    ? art.TestERC20.bytecode
    : '0x' + art.TestERC20.bytecode;

  const start = state.tokens.length;
  const remaining = cfg.tokenCount - start;
  if (remaining > 0) {
    console.log('');
    console.log(`==> [2/3] 部署 ${fmtNum(remaining)} 个 TestERC20（${start} 已存在跳过）`);
    console.log(`    initial supply 每个 = ${cfg.tokenInitialSupply / 10n ** 18n} 个 token`);

    // 用 sendBatchSigned 走 JSON-RPC batch（避免 viem 并发乱序撞 op-geth 的 accountQueue 上限）
    // 50 在 60M gas/block 限制下 1 个块装得下（50 × 600k = 30M）
    const IN_FLIGHT = parseInt(process.env.DEPLOY_IN_FLIGHT || '50');
    let succ = 0, fail = 0;
    const t0 = Date.now();

    for (let off = 0; off < remaining; off += IN_FLIGHT) {
      const slice = [];
      for (let j = 0; j < IN_FLIGHT && off + j < remaining; j++) {
        const idx = start + off + j;
        const data = encodeDeployData({
          abi: erc20Abi,
          bytecode: erc20Bytecode,
          args: [`TestToken${idx}`, `TT${idx}`, cfg.tokenInitialSupply, deployer.address],
        });
        slice.push({
          to: undefined,                 // deploy: no `to`
          data,
          gas: 1200000n,
          // nonce 在循环末尾按"成功才推进"原则增量；这里只加 j（offset 已隐含在 nonce 累加里）
          nonce: nonce + j,
          label: `deploy#${idx}`,
          _meta: { idx, name: `TestToken${idx}`, symbol: `TT${idx}` },
        });
      }

      const { accepted, lastHash } = await sendBatchSigned(deployer, slice);
      fail += slice.length - accepted.length;

      // 等本批最后一个 hash 进块
      if (lastHash) {
        try {
          await publicClient.waitForTransactionReceipt({ hash: lastHash, timeout: 180000 });
        } catch (e) {
          console.error(`\n  ⚠️ deploy 等批末超时（lastHash=${lastHash.slice(0, 18)}...）：${explainErr(e)}`);
        }
      }

      // 拉 receipt 取 contractAddress
      const rcpts = await Promise.all(accepted.map(async x => {
        try {
          const rc = await publicClient.getTransactionReceipt({ hash: x.hash });
          return rc && rc.status === 'success' ? rc.contractAddress : null;
        } catch { return null; }
      }));
      for (let i = 0; i < accepted.length; i++) {
        const addr = rcpts[i];
        if (addr) {
          state.tokens.push({
            address: addr,
            name: accepted[i].tx._meta.name,
            symbol: accepted[i].tx._meta.symbol,
            holders: [],
          });
          succ++;
        } else {
          // tx accepted by mempool 但 contract 没 mined 出地址（OOG / revert）
          fail++;
        }
      }

      // nonce 推进：全成功就 += slice.length；有失败就从链上重拉（避免跳号传染下一批）
      if (accepted.length === slice.length) {
        nonce += slice.length;
      } else {
        nonce = await publicClient.getTransactionCount({ address: deployer.address });
      }
      saveTokens(state);
      const elapsed = ((Date.now() - t0) / 1000).toFixed(1);
      process.stdout.write(`\r    部署 ${succ}/${remaining}（失败 ${fail}） ${elapsed}s   `);
    }
    console.log('');
    console.log(`    ✅ 部署完成（成功 ${succ}，失败 ${fail}），用时 ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  } else {
    console.log(`==> [2/3] ${cfg.tokenCount} 个 TestERC20 已全部部署，跳过`);
  }

  // 3. 给 BatchTransfer 授权 max（每个 token 一次 approve；deployer = msg.sender）
  console.log('');
  console.log(`==> [3/3] 给 BatchTransfer 授权 max（${fmtNum(state.tokens.length)} 个 token）`);
  console.log(`    BatchTransfer @ ${state.batchTransfer}`);

  // 用 JSON-RPC batch 发 approve（同 deploy 一样，避免 viem 并发 RPC 乱序）
  nonce = await publicClient.getTransactionCount({ address: deployer.address });
  const APPROVE_IN_FLIGHT = parseInt(process.env.APPROVE_IN_FLIGHT || '50');
  const tokensToApprove = state.tokens;  // approve max 是幂等的
  let approvedOk = 0, approvedFail = 0;
  const tA = Date.now();

  for (let off = 0; off < tokensToApprove.length; off += APPROVE_IN_FLIGHT) {
    const slice = tokensToApprove.slice(off, off + APPROVE_IN_FLIGHT);
    const txs = slice.map((tok, j) => ({
      to: tok.address,
      data: encodeFunctionData({
        abi: erc20Abi,
        functionName: 'approve',
        args: [state.batchTransfer, 2n ** 256n - 1n],
      }),
      gas: 80000n,
      nonce: nonce + j,
      label: `approve#${off + j}`,
    }));
    const { accepted, failed, lastHash } = await sendBatchSigned(deployer, txs);
    approvedOk += accepted.length;
    approvedFail += failed.length;
    if (lastHash) {
      try { await publicClient.waitForTransactionReceipt({ hash: lastHash, timeout: 180000 }); }
      catch (e) { console.error(`\n  ⚠️ approve 等批末超时：${explainErr(e)}`); }
    }
    if (accepted.length === slice.length) {
      nonce += slice.length;
    } else {
      nonce = await publicClient.getTransactionCount({ address: deployer.address });
    }
    process.stdout.write(`\r    approve ${off + slice.length}/${tokensToApprove.length}（失败 ${approvedFail}） ${((Date.now() - tA) / 1000).toFixed(1)}s   `);
  }
  console.log('');
  console.log(`    ✅ approve 完成（成功 ${approvedOk}，失败 ${approvedFail}）`);
  console.log('');
  console.log(`==> 全部完成，状态写入 ${cfg.tokensFile}`);
  console.log(`    BatchTransfer ${state.batchTransfer}`);
  console.log(`    ${state.tokens.length} 个 ERC-20 token`);
}

// -----------------------------------------------------------------------------
// 子命令: fund-gas  给所有钱包打 gas（用 BatchTransfer.batchSendNative 一次 200 个）
// -----------------------------------------------------------------------------
async function cmdFundGas() {
  if (!cfg.deployerKey) { console.error('❌ 缺 DEPLOYER_PRIVATE_KEY'); process.exit(1); }
  const deployer = privateKeyToAccount(cfg.deployerKey);
  const wc = createWalletClient({ account: deployer, chain, transport: http(cfg.rpcUrl) });
  const art = loadArtifacts();
  const state = loadTokens();
  if (!state || !state.batchTransfer) {
    console.error(`❌ 没找到 BatchTransfer，先 make bot-token-deploy`);
    process.exit(1);
  }
  const wallets = loadWallets();
  if (wallets.length !== cfg.walletCount) {
    console.error(`❌ 钱包数 ${wallets.length} != ${cfg.walletCount}，先 make bot-token-init`);
    process.exit(1);
  }

  const amount = parseEther(cfg.fundGasAmount.toString());
  const total = amount * BigInt(wallets.length);
  // batchSendNative 单 tx ~50k + N×30k gas
  const batchGas = BigInt(50000 + cfg.fundBatchSize * 35000);
  const numBatches = Math.ceil(wallets.length / cfg.fundBatchSize);
  const gasCost = BigInt(numBatches) * batchGas * cfg.gasPrice;
  const need = total + gasCost;
  const bal = await publicClient.getBalance({ address: deployer.address });

  console.log(`==> Deployer ${deployer.address}`);
  console.log(`    余额 ${formatEther(bal)} MAN`);
  console.log(`==> 给 ${fmtNum(wallets.length)} 钱包各打 ${cfg.fundGasAmount} MAN`);
  console.log(`    转出 ${formatEther(total)} MAN`);
  console.log(`    Gas  ${formatEther(gasCost)} MAN (${numBatches} batches × ${cfg.fundBatchSize} recipients)`);
  console.log(`    合计 ${formatEther(need)} MAN`);
  if (bal < need) {
    console.error(`❌ 余额不够，差 ${formatEther(need - bal)} MAN`);
    console.error(`   make bot-token-mint AMOUNT=${Math.ceil(parseFloat(formatEther(need - bal)) + 100)}`);
    process.exit(1);
  }

  // skip 已经有 gas 的钱包：拉一次余额（JSON-RPC batch），过滤
  console.log('');
  console.log('==> 检查已有余额（JSON-RPC batch），跳过已经 fund 过的');
  const haveBalances = await batchGetBalances(wallets.map(w => w.address));
  const minSkip = parseEther((cfg.fundGasAmount * 0.5).toFixed(6));  // 余额 >=50% 就跳过
  const toFund = [];
  for (let i = 0; i < wallets.length; i++) {
    if (haveBalances[i] < minSkip) toFund.push(wallets[i].address);
  }
  console.log(`    需要打 ${fmtNum(toFund.length)} / 跳过 ${fmtNum(wallets.length - toFund.length)}`);
  if (toFund.length === 0) {
    console.log('✅ 全部钱包已有 gas 余额，跳过');
    return;
  }

  const realBatches = Math.ceil(toFund.length / cfg.fundBatchSize);
  console.log(`    实际 ${realBatches} batches × ≤${cfg.fundBatchSize}`);
  console.log('');

  let nonce = await publicClient.getTransactionCount({ address: deployer.address });
  console.log(`    起始 nonce ${nonce}`);

  const batchTransferAbi = art.BatchTransfer.abi;
  const t0 = Date.now();
  let succ = 0, fail = 0;
  // 用 sendBatchSigned 走 JSON-RPC batch（避免 viem 并发乱序）。
  // 每批 30 笔（每笔 batchSendNative 200 个 recipient ≈ 7.7M gas → 30 × 7.7M = 230M ≈ 4 块）
  const IN_FLIGHT = parseInt(process.env.FUND_GAS_IN_FLIGHT || '30');

  for (let off = 0; off < toFund.length; off += cfg.fundBatchSize * IN_FLIGHT) {
    const slices = [];
    for (let i = 0; i < IN_FLIGHT && off + i * cfg.fundBatchSize < toFund.length; i++) {
      const start = off + i * cfg.fundBatchSize;
      const end = Math.min(start + cfg.fundBatchSize, toFund.length);
      slices.push(toFund.slice(start, end));
    }

    const txs = slices.map((recipients, j) => ({
      to: state.batchTransfer,
      data: encodeFunctionData({
        abi: batchTransferAbi,
        functionName: 'batchSendNative',
        args: [recipients, amount],
      }),
      value: amount * BigInt(recipients.length),
      gas: BigInt(80000 + recipients.length * 35000),
      nonce: nonce + j,
      label: `fund#${off + j * cfg.fundBatchSize}`,
    }));
    const { accepted, lastHash } = await sendBatchSigned(deployer, txs);
    // accepted 是 tx 引用集合；按 tx 引用匹配到对应 slice 算 recipients 个数
    const acceptedSet = new Set(accepted.map(a => a.tx));
    for (let i = 0; i < txs.length; i++) {
      if (acceptedSet.has(txs[i])) succ += slices[i].length;
      else fail += slices[i].length;
    }
    if (lastHash) {
      try { await publicClient.waitForTransactionReceipt({ hash: lastHash, timeout: 180000 }); }
      catch (e) { console.error(`\n  ⚠️ fund 等批末超时：${explainErr(e)}`); }
    }
    if (accepted.length === slices.length) {
      nonce += slices.length;
    } else {
      nonce = await publicClient.getTransactionCount({ address: deployer.address });
    }
    process.stdout.write(`\r    已 fund ${fmtNum(succ)}/${fmtNum(toFund.length)}（失败 ${fail}） ${((Date.now() - t0) / 1000).toFixed(1)}s   `);
  }
  console.log('');
  console.log(`✅ fund-gas 完成：成功 ${fmtNum(succ)}，失败 ${fail}，用时 ${((Date.now() - t0) / 1000).toFixed(1)}s`);
}

// -----------------------------------------------------------------------------
// 共享：高吞吐发送一批 deployer EOA 的 EIP-1559 tx
//   - 本地按序签名（secp256k1 单线程，~0.5ms/tx）
//   - 用 JSON-RPC batch 一个 HTTP 装全部 eth_sendRawTransaction
//   - 等本批最后成功的 hash 进块
//
// 输入：account（带私钥的 viem account）+ txs 数组，每个 tx 元素：
//   { to?, data?, value?, gas, nonce, label }   label 仅用于错误日志
// 返回：{ accepted: [{ tx, hash }], failed: [{ tx, err }], lastHash }
// -----------------------------------------------------------------------------
async function sendBatchSigned(account, txs, opts = {}) {
  const errLogMax = opts.errLogMax ?? 3;
  let errLogged = 0;

  // 1. 本地签名
  const signed = [];
  const failed = [];
  for (const tx of txs) {
    try {
      const raw = await account.signTransaction({
        type: 'eip1559',
        chainId: cfg.chainId,
        to: tx.to,
        data: tx.data,
        value: tx.value,
        gas: tx.gas,
        nonce: tx.nonce,
        maxFeePerGas: MAX_FEE_PER_GAS,
        maxPriorityFeePerGas: MAX_PRIORITY_FEE_PER_GAS,
      });
      signed.push({ tx, raw });
    } catch (e) {
      failed.push({ tx, err: e });
      if (errLogged < errLogMax) {
        console.error(`\n  ⚠️ 签名失败 ${tx.label || ''} nonce=${tx.nonce}: ${explainErr(e)}`);
        errLogged++;
      }
    }
  }
  if (!signed.length) return { accepted: [], failed, lastHash: null };

  // 2. JSON-RPC batch 发送
  let responses;
  try {
    responses = await rpcBatch(signed.map(x => ['eth_sendRawTransaction', [x.raw]]));
  } catch (e) {
    // 整个 HTTP 失败 — 全部当 failed
    for (const x of signed) failed.push({ tx: x.tx, err: e });
    console.error(`\n  ⚠️ rpcBatch HTTP fail: ${explainErr(e)}`);
    return { accepted: [], failed, lastHash: null };
  }

  // 3. 收集成功 / 失败
  const accepted = [];
  let lastHash = null;
  for (let i = 0; i < signed.length; i++) {
    const r = responses[i];
    if (r && r.result) {
      accepted.push({ tx: signed[i].tx, hash: r.result });
      lastHash = r.result;
    } else {
      failed.push({ tx: signed[i].tx, err: r && r.error });
      if (errLogged < errLogMax && r && r.error) {
        console.error(`\n  ⚠️ send 失败 ${signed[i].tx.label || ''} nonce=${signed[i].tx.nonce}: ${r.error.message || JSON.stringify(r.error)}`);
        errLogged++;
      }
    }
  }
  return { accepted, failed, lastHash };
}

// -----------------------------------------------------------------------------
// 共享：JSON-RPC batch 拉 N 个地址余额 / nonce
//   每 100 个一组，并发 10 组 → 50000 个用 ~3-5s
// -----------------------------------------------------------------------------
async function batchGetGeneric(method, addresses) {
  const BATCH = 100;
  const CONCURRENCY = 10;
  const result = new Array(addresses.length);
  const batches = [];
  for (let i = 0; i < addresses.length; i += BATCH) {
    batches.push({ start: i, end: Math.min(i + BATCH, addresses.length) });
  }
  let cursor = 0;
  await Promise.all(Array(CONCURRENCY).fill(0).map(async () => {
    while (true) {
      const my = cursor++;
      if (my >= batches.length) return;
      const b = batches[my];
      const slice = addresses.slice(b.start, b.end);
      const reqs = slice.map(addr => [method, [addr, 'latest']]);
      let arr;
      try { arr = await rpcBatch(reqs); }
      catch (e) { console.error(`\n  ⚠️ batch ${my} fail: ${explainErr(e)}, 重试`); cursor--; await new Promise(r => setTimeout(r, 500)); continue; }
      for (let j = 0; j < arr.length; j++) {
        const r = arr[j];
        if (r && r.result !== undefined) {
          result[b.start + j] = BigInt(r.result);
        } else {
          result[b.start + j] = 0n;
        }
      }
    }
  }));
  return result;
}
async function batchGetBalances(addresses) {
  return batchGetGeneric('eth_getBalance', addresses);
}
async function batchGetNonces(addresses) {
  const arr = await batchGetGeneric('eth_getTransactionCount', addresses);
  return arr.map(b => Number(b));
}

// -----------------------------------------------------------------------------
// 子命令: seed  每个 token 随机选 N 个 holder，BatchTransfer 一次 200 个
// -----------------------------------------------------------------------------
async function cmdSeed() {
  if (!cfg.deployerKey) { console.error('❌ 缺 DEPLOYER_PRIVATE_KEY'); process.exit(1); }
  const deployer = privateKeyToAccount(cfg.deployerKey);
  const wc = createWalletClient({ account: deployer, chain, transport: http(cfg.rpcUrl) });
  const art = loadArtifacts();
  const state = loadTokens();
  if (!state || !state.batchTransfer || state.tokens.length === 0) {
    console.error(`❌ 没部署 token，先 make bot-token-deploy`);
    process.exit(1);
  }
  const wallets = loadWallets();
  if (wallets.length !== cfg.walletCount) {
    console.error(`❌ 钱包数 ${wallets.length} != ${cfg.walletCount}`);
    process.exit(1);
  }

  console.log(`==> 给 ${fmtNum(state.tokens.length)} 个 token 各随机选 ${cfg.holdersPerToken} 个 holder 并分发种子`);
  console.log(`    种子额度 ${cfg.seedAmount / 10n ** 18n} 个 token / holder`);
  console.log(`    单 batch 200 个 recipient，每 token 需要 ${Math.ceil(cfg.holdersPerToken / cfg.seedBatchSize)} 个 batch`);

  const totalSeedTx = state.tokens.length * Math.ceil(cfg.holdersPerToken / cfg.seedBatchSize);
  console.log(`    总 seed tx ~ ${fmtNum(totalSeedTx)}`);

  // 给每个 token 选随机 holder（不重复），写入 state.tokens[i].holders
  // holders 数组里存 wallet index（紧凑）
  let seeded = 0;
  for (const tok of state.tokens) {
    if (tok.holders.length >= cfg.holdersPerToken) seeded++;
  }
  if (seeded === state.tokens.length) {
    console.log('✅ 所有 token 已 seed 过，跳过');
    return;
  }
  console.log(`    已 seed ${seeded} / 待 seed ${state.tokens.length - seeded}`);
  console.log('');

  const batchTransferAbi = art.BatchTransfer.abi;
  let nonce = await publicClient.getTransactionCount({ address: deployer.address });
  console.log(`    起始 nonce ${nonce}`);

  // 队列化所有 (token, recipient[]) 任务
  const jobs = [];
  for (let ti = 0; ti < state.tokens.length; ti++) {
    const tok = state.tokens[ti];
    if (tok.holders.length >= cfg.holdersPerToken) continue;
    // 选 cfg.holdersPerToken 个不重复的 wallet idx
    const need = cfg.holdersPerToken - tok.holders.length;
    const usedSet = new Set(tok.holders);
    while (tok.holders.length < cfg.holdersPerToken) {
      const i = Math.floor(Math.random() * wallets.length);
      if (usedSet.has(i)) continue;
      usedSet.add(i);
      tok.holders.push(i);
    }
    // 切 batch
    const newHolders = tok.holders.slice(tok.holders.length - need);
    for (let off = 0; off < newHolders.length; off += cfg.seedBatchSize) {
      const slice = newHolders.slice(off, off + cfg.seedBatchSize);
      jobs.push({ tokenIdx: ti, recipients: slice.map(idx => wallets[idx].address) });
    }
  }
  console.log(`    总 batch tx = ${fmtNum(jobs.length)}`);

  const t0 = Date.now();
  let succ = 0, fail = 0;
  // 用 sendBatchSigned 走 JSON-RPC batch（避免 viem 并发乱序）
  // 每批 30 笔（每笔 batchTransferFrom 200 个 recipient ≈ 6.6M gas → 30 × 6.6M = 200M ≈ 3.3 块）
  const IN_FLIGHT = parseInt(process.env.SEED_IN_FLIGHT || '30');

  for (let off = 0; off < jobs.length; off += IN_FLIGHT) {
    const slice = jobs.slice(off, off + IN_FLIGHT);
    const txs = slice.map((job, j) => {
      const tok = state.tokens[job.tokenIdx];
      return {
        to: state.batchTransfer,
        data: encodeFunctionData({
          abi: batchTransferAbi,
          functionName: 'batchTransferFrom',
          args: [tok.address, deployer.address, job.recipients, cfg.seedAmount],
        }),
        gas: BigInt(60000 + job.recipients.length * 30000),
        nonce: nonce + j,
        label: `seed#${off + j}(token${job.tokenIdx})`,
      };
    });
    const { accepted, lastHash } = await sendBatchSigned(deployer, txs);
    succ += accepted.length;
    fail += slice.length - accepted.length;
    if (lastHash) {
      try { await publicClient.waitForTransactionReceipt({ hash: lastHash, timeout: 180000 }); }
      catch (e) { console.error(`\n  ⚠️ seed 等批末超时：${explainErr(e)}`); }
    }
    if (accepted.length === slice.length) {
      nonce += slice.length;
    } else {
      nonce = await publicClient.getTransactionCount({ address: deployer.address });
    }
    saveTokens(state);  // 持久化 holder 列表
    process.stdout.write(`\r    seed batch ${off + slice.length}/${jobs.length}（失败 ${fail}） ${((Date.now() - t0) / 1000).toFixed(1)}s   `);
  }
  console.log('');
  console.log(`✅ seed 完成：成功 ${fmtNum(succ)}，失败 ${fail}，用时 ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  console.log(`   tokens.json 已更新（${cfg.tokenCount} token，每 token ${cfg.holdersPerToken} holder）`);
}

// -----------------------------------------------------------------------------
// 子命令: spam  高吞吐 ERC-20 互转，目标 TARGET_TPS
// -----------------------------------------------------------------------------
async function cmdSpam() {
  const wallets = loadWallets();
  const state = loadTokens();
  if (!state || !state.tokens.length) {
    console.error(`❌ 没部署 token，先 make bot-token-deploy && bot-token-seed`);
    process.exit(1);
  }
  if (wallets.length !== cfg.walletCount) {
    console.error(`❌ 钱包数 ${wallets.length} != ${cfg.walletCount}`);
    process.exit(1);
  }

  // 校验：所有 token 都被 seed 过
  const unseeded = state.tokens.filter(t => t.holders.length === 0);
  if (unseeded.length) {
    console.error(`❌ ${unseeded.length} 个 token 没 seed，先 make bot-token-seed`);
    process.exit(1);
  }

  console.log('');
  console.log(`==> SPAM 配置`);
  console.log(`    target TPS         ${cfg.targetTps}`);
  console.log(`    tick               ${cfg.spamTickMs}ms`);
  const txPerTick = Math.ceil(cfg.targetTps * cfg.spamTickMs / 1000);
  console.log(`    tx / tick          ${txPerTick}`);
  console.log(`    max tick in flight ${parseInt(process.env.MAX_TICK_QUEUE || '8')}（= 同时在路上的 RPC batch 数）`);
  console.log(`    HTTP connections   ${HTTP_CONNECTIONS}（undici 全局连接池上限）`);
  console.log(`    spam send RPC      ${cfg.spamRpcUrl}`);
  console.log(`    diag/mempool RPC   ${cfg.diagRpcUrl}`);
  if (cfg.spamRpcUrl !== cfg.rpcUrl || cfg.diagRpcUrl !== cfg.rpcUrl) {
    console.log(`    (general RPC       ${cfg.rpcUrl})`);
  }
  if (process.env.MEMPOOL_BACKPRESSURE === '0') {
    console.log(`    mempool backpressure  关闭（容易雪崩，不推荐）`);
  } else {
    console.log(`    mempool backpressure  pending+queued ≥ ${process.env.MEMPOOL_HIGH_WATER || '3000'} 暂停 / ≤ ${process.env.MEMPOOL_LOW_WATER || '1000'} 恢复`);
  }
  console.log(`    transfer amount    ${cfg.spamAmountWei} wei (= ${Number(cfg.spamAmountWei) / 1e18} token)`);
  console.log(`    tokens             ${fmtNum(state.tokens.length)}`);
  console.log(`    holders / token    ${cfg.holdersPerToken}`);
  console.log(`    wallets (recipients) ${fmtNum(wallets.length)}`);
  console.log('');

  // 1. viem account 对象（50000 个 privateKeyToAccount，约 1-2 秒）
  console.log('==> 初始化 50000 个 viem account 对象 ...');
  const t0 = Date.now();
  const accounts = wallets.map(w => privateKeyToAccount(w.privateKey));
  console.log(`    ${((Date.now() - t0) / 1000).toFixed(1)}s`);

  // 2. JSON-RPC batch 拉 nonce（500 个 batch × 100 call，并发 10）
  console.log(`==> JSON-RPC 批量拉 ${fmtNum(wallets.length)} 个 nonce ...`);
  const t1 = Date.now();
  const addrs = wallets.map(w => w.address);
  const nonces = await batchGetNonces(addrs);
  console.log(`    ${((Date.now() - t1) / 1000).toFixed(1)}s`);

  // 3. 构造紧凑 sender state
  // 用数组存而不是 Map，索引 = wallet idx；快很多
  const senderState = new Array(wallets.length);
  let activeCount = 0;
  for (let i = 0; i < wallets.length; i++) {
    senderState[i] = { account: accounts[i], nonce: nonces[i] };
    if (nonces[i] > 0) activeCount++;
  }
  console.log(`    其中已发过 tx 的 ${fmtNum(activeCount)} 个`);

  // 4. 预编码每个 token 的 transfer(to, amount) selector：
  // 实际 to 在每笔 tx 才知道，所以只能预编 selector + amount
  // 直接用 viem encodeFunctionData 也行，~10us/call，可以接受
  const erc20Abi = state ? null : null;  // 用直接 selector，不依赖 ABI
  // transfer(address,uint256) = 0xa9059cbb
  const TRANSFER_SELECTOR = '0xa9059cbb';
  const amountHex = cfg.spamAmountWei.toString(16).padStart(64, '0');
  function encodeTransfer(toAddr) {
    // 0x + 4 字节 selector + 32 字节 to (zero-padded) + 32 字节 amount
    const toPad = toAddr.toLowerCase().replace('0x', '').padStart(64, '0');
    return TRANSFER_SELECTOR + toPad + amountHex;
  }

  // 5. spam loop
  const stats = {
    ok: 0, fail: 0,
    // fail 按类型分类（fail-fast 模式下区分链层 reject 是否可控很重要）
    failTxpoolFull: 0,    // "txpool is full" — op-geth mempool 满，链层 fail-fast
    failNonce: 0,         // nonce too low / high / known / replacement underpriced
    failOther: 0,         // gas / balance / revert / 其他
    // debug：sample 前 5 个无法分类的 error 原文（v6 实测发现 fail.full=0 但 fail 数很高，
    // 说明 op-geth 实际错误信息可能跟 spammer keyword check 不匹配）
    sampledErrs: [],
    started: Date.now(), lastReport: Date.now(), lastOk: 0, lastFail: 0,
    // RPC batch 延迟环形缓冲（最近 200 个）
    rpcLatMs: new Float64Array(200),
    rpcLatIdx: 0,
    rpcLatCount: 0,
  };
  function recordLat(ms) {
    stats.rpcLatMs[stats.rpcLatIdx] = ms;
    stats.rpcLatIdx = (stats.rpcLatIdx + 1) % stats.rpcLatMs.length;
    if (stats.rpcLatCount < stats.rpcLatMs.length) stats.rpcLatCount++;
  }
  function pctLat(q) {
    if (stats.rpcLatCount === 0) return 0;
    const arr = Array.from(stats.rpcLatMs.subarray(0, stats.rpcLatCount)).sort((a, b) => a - b);
    return Math.round(arr[Math.min(arr.length - 1, Math.floor(arr.length * q))]);
  }
  const busy = new Uint8Array(wallets.length);  // 0/1，避免 Set GC 抖动

  const fireTick = async () => {
    // 选 txPerTick 个不重复的 (token, holder) 对
    const picks = [];
    let attempts = 0;
    const usedThisTick = new Set();
    while (picks.length < txPerTick && attempts < txPerTick * 6) {
      attempts++;
      const tok = state.tokens[Math.floor(Math.random() * state.tokens.length)];
      if (tok.holders.length === 0) continue;
      const senderIdx = tok.holders[Math.floor(Math.random() * tok.holders.length)];
      if (usedThisTick.has(senderIdx)) continue;
      if (busy[senderIdx]) continue;
      const recipientIdx = Math.floor(Math.random() * wallets.length);
      if (recipientIdx === senderIdx) continue;
      picks.push({ tok, senderIdx, recipientIdx });
      usedThisTick.add(senderIdx);
    }
    if (!picks.length) return;

    // 标 busy + 签名（并行）
    for (const p of picks) busy[p.senderIdx] = 1;

    const signed = await Promise.all(picks.map(async (p) => {
      const s = senderState[p.senderIdx];
      const data = encodeTransfer(wallets[p.recipientIdx].address);
      const nonce = s.nonce++;
      try {
        const raw = await s.account.signTransaction({
          type: 'eip1559',
          chainId: cfg.chainId,
          to: p.tok.address,
          data,
          value: 0n,
          nonce,
          gas: 100000n,
          maxFeePerGas: MAX_FEE_PER_GAS,
          maxPriorityFeePerGas: MAX_PRIORITY_FEE_PER_GAS,
        });
        return { raw, p, nonce };
      } catch (e) {
        s.nonce = nonce;  // 回滚
        busy[p.senderIdx] = 0;
        stats.fail++;
        return null;
      }
    }));
    const valid = signed.filter(Boolean);
    if (!valid.length) return;

    // JSON-RPC batch 一次性发出去（spam 路径走 spamRpcUrl，Flashblocks 后切到 op-rbuilder）
    let responses;
    const rpcT0 = Date.now();
    try {
      responses = await rpcBatch(
        valid.map(v => ['eth_sendRawTransaction', [v.raw]]),
        cfg.spamRpcUrl,
      );
    } catch (e) {
      recordLat(Date.now() - rpcT0);
      // 整批失败：rollback nonce + busy
      for (const v of valid) {
        senderState[v.p.senderIdx].nonce = v.nonce;
        busy[v.p.senderIdx] = 0;
        stats.fail++;
      }
      return;
    }
    recordLat(Date.now() - rpcT0);

    // 处理每个响应
    for (let i = 0; i < valid.length; i++) {
      const v = valid[i];
      const resp = responses[i];
      busy[v.p.senderIdx] = 0;
      if (resp && resp.result) {
        stats.ok++;
      } else {
        stats.fail++;
        const rawErr = (resp && resp.error && resp.error.message) || '';
        const errMsg = rawErr.toLowerCase();
        // fail-fast 路径：op-geth mempool 满拒绝
        // 实测 op-geth v1.101702.1 在 mempool 满时返回的错误可能是：
        //   - "txpool is full" (go-ethereum 标准)
        //   - "txpool overflow"
        //   - "tx pool full" / "txpool overflowed"
        //   - 也可能 op-geth fork 改了字符串
        // 用宽松匹配：包含 "pool" + ("full" / "overflow" / "limit") 都算
        const isPoolFull = (
          (errMsg.includes('pool') && (errMsg.includes('full') || errMsg.includes('overflow') || errMsg.includes('limit'))) ||
          errMsg.includes('queue full') ||
          errMsg.includes('mempool is full')
        );
        if (isPoolFull) {
          stats.failTxpoolFull++;
          // 不动 nonce —— 这笔被丢就当从来没发过，下次 tick 用同一个 nonce 重发别的 sender 即可
          senderState[v.p.senderIdx].nonce = v.nonce;
        } else if (errMsg.includes('nonce') || errMsg.includes('underpriced') || errMsg.includes('replacement') || errMsg.includes('known')) {
          stats.failNonce++;
          // 异步重新拉这个账户的 nonce
          publicClient.getTransactionCount({ address: senderState[v.p.senderIdx].account.address })
            .then(n => { senderState[v.p.senderIdx].nonce = n; })
            .catch(() => {});
        } else {
          stats.failOther++;
          // 其它错误（gas / balance / revert）：回滚 nonce 并保守处理
          senderState[v.p.senderIdx].nonce = v.nonce;
          // sample 前 5 个 unclassified error 原文（debug 用）
          if (rawErr && stats.sampledErrs.length < 5) {
            stats.sampledErrs.push(rawErr.slice(0, 200));
            console.log(`  [DEBUG] unclassified error sample #${stats.sampledErrs.length}: ${rawErr.slice(0, 200)}`);
          }
        }
      }
    }
  };

  // daemon 模式 stdout 是 pipe（行缓冲），\r 不触发 flush 导致 docker logs 看不到任何输出。
  // 这里用 console.log（带 \n 触发 flush），TTY 下虽然每条单独一行不太精简，但 daemon 才是常态
  console.log('');
  console.log(`==> 开始 SPAM（Ctrl+C 退；report 每 2s 一行）`);
  console.log('');

  let inTickFlight = 0;
  // 并发批数：默认 16。
  //
  // 实测 (2025-04, full+path scheme + 10k IOPS NVMe + 8 核 Xeon)：
  //   - mempool 干净时：32 并发 → sustained 900 TPS（op-geth CPU 多核打满）
  //   - mempool 大（pending > 10000）：32 并发会触发 op-geth 选 tx 退化
  //     → 每块只塞 1 笔，sustained 跌到 50 TPS
  //   - 8 并发：mempool 健康时 sustained 500 TPS（保守）
  //   - 16 并发：mempool 健康时 sustained 700-900 TPS，相对稳健的折中
  //
  // 想冲 1000 TPS 峰值用 32；想长跑稳定用 8-16。op-geth 慢了 setInterval
  // 跳过本 tick，不堆积。
  const MAX_TICK_QUEUE = parseInt(process.env.MAX_TICK_QUEUE || '8');

  // -----------------------------------------------------------------------
  // mempool 自适应背压
  // -----------------------------------------------------------------------
  // op-geth 在 mempool 大（pending > 10000）时 worker 选 tx 严重退化：
  // 每个 block 只塞 1-2 笔，sustained TPS 从 900 跌到 30。
  //
  // 防御策略：每 2s 查一次 mempool，pending 超过 high-water 就暂停发新 tx，
  // 等 mempool 自己被 sequencer 消化到 low-water 以下再恢复。这样 spammer
  // 自动跟链的真实容量同步，永远不让 mempool 积压到雪崩点。
  //
  // 关 backpressure：MEMPOOL_BACKPRESSURE=0
  const BP_ENABLED   = process.env.MEMPOOL_BACKPRESSURE !== '0';
  const BP_HIGH      = parseInt(process.env.MEMPOOL_HIGH_WATER || '3000');
  const BP_LOW       = parseInt(process.env.MEMPOOL_LOW_WATER  || '1000');
  const BP_INTERVAL  = parseInt(process.env.MEMPOOL_CHECK_MS   || '2000');
  let throttled = false;
  let lastMempool = { pending: 0, queued: 0 };

  async function checkMempool() {
    try {
      // 监控的对象必须是真正出块的 sequencer EL（Flashblocks 后 = op-rbuilder）
      const res = await fetch(cfg.diagRpcUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', method: 'txpool_status', params: [], id: 1 }),
      });
      if (!res.ok) return;
      const j = await res.json();
      if (!j.result) return;
      const pending = parseInt(j.result.pending, 16);
      const queued  = parseInt(j.result.queued, 16);
      lastMempool = { pending, queued };
      if (!BP_ENABLED) return;
      const total = pending + queued;
      if (!throttled && total >= BP_HIGH) {
        throttled = true;
        console.log(`  ⚠️  mempool ${total}（pending=${pending} queued=${queued}）≥ HIGH=${BP_HIGH}，暂停发送等消化`);
      } else if (throttled && total <= BP_LOW) {
        throttled = false;
        console.log(`  ✅ mempool ${total} ≤ LOW=${BP_LOW}，恢复发送`);
      }
    } catch (e) {
      // 静默失败，下次再查
    }
  }
  // 启动后立刻查一次，再周期查
  checkMempool();
  const mempoolHandle = setInterval(checkMempool, BP_INTERVAL);

  const tickHandle = setInterval(() => {
    if (throttled) return;                       // 背压：暂停本 tick
    if (inTickFlight >= MAX_TICK_QUEUE) return;  // 跳过本 tick
    inTickFlight++;
    fireTick().catch(e => {
      console.error(`tick error: ${explainErr(e)}`);
    }).finally(() => { inTickFlight--; });
  }, cfg.spamTickMs);

  const reportHandle = setInterval(() => {
    const now = Date.now();
    const overall = stats.ok / ((now - stats.started) / 1000);
    const recent = (stats.ok - stats.lastOk) / ((now - stats.lastReport) / 1000);
    const recentFail = (stats.fail - stats.lastFail) / ((now - stats.lastReport) / 1000);
    stats.lastOk = stats.ok;
    stats.lastFail = stats.fail;
    stats.lastReport = now;
    const mp = `mp=${lastMempool.pending}+${lastMempool.queued}${throttled ? '⏸' : ''}`;
    // fail 类型一行（仅在有 fail 时打印，避免噪音）
    const fb = stats.failTxpoolFull, fn = stats.failNonce, fo = stats.failOther;
    const failBreakdown = (fb + fn + fo) > 0
      ? ` fail{full=${fmtNum(fb)},nonce=${fmtNum(fn)},other=${fmtNum(fo)}}`
      : '';
    console.log(
      `[${((now - stats.started) / 1000).toFixed(0).padStart(5)}s] ` +
      `ok=${fmtNum(stats.ok).padStart(9)} fail=${fmtNum(stats.fail).padStart(7)} ` +
      `tps(rec)=${recent.toFixed(0).padStart(4)} ftps(rec)=${recentFail.toFixed(0).padStart(4)} ` +
      `tps(avg)=${overall.toFixed(0).padStart(4)} ` +
      `q=${String(inTickFlight).padStart(2)}/${MAX_TICK_QUEUE} ` +
      `rpc(p50/p95/max)=${pctLat(0.5)}/${pctLat(0.95)}/${pctLat(0.999)}ms ` +
      mp + failBreakdown
    );
  }, 2000);

  const onShutdown = (sig) => {
    clearInterval(tickHandle);
    clearInterval(reportHandle);
    clearInterval(mempoolHandle);
    const dt = (Date.now() - stats.started) / 1000;
    console.log('');
    console.log(`==> 收到 ${sig}，停止`);
    console.log(`    总 ok=${fmtNum(stats.ok)}, fail=${fmtNum(stats.fail)} (full=${fmtNum(stats.failTxpoolFull)} nonce=${fmtNum(stats.failNonce)} other=${fmtNum(stats.failOther)}), ${dt.toFixed(1)}s, avg ${(stats.ok / dt).toFixed(1)} TPS`);
    process.exit(0);
  };
  process.on('SIGINT', () => onShutdown('SIGINT'));
  process.on('SIGTERM', () => onShutdown('SIGTERM'));
}

// -----------------------------------------------------------------------------
// 子命令: status
// -----------------------------------------------------------------------------
async function cmdStatus() {
  console.log(`==> tokenspammer 状态`);
  console.log('');

  const wallets = loadWallets();
  console.log(`钱包文件      ${cfg.walletsFile}`);
  console.log(`钱包数        ${fmtNum(wallets.length)} / 目标 ${fmtNum(cfg.walletCount)}`);

  const state = loadTokens();
  console.log(`tokens 文件   ${cfg.tokensFile}`);
  if (state) {
    console.log(`BatchTransfer ${state.batchTransfer || '(未部署)'}`);
    console.log(`Deployer      ${state.deployer}`);
    console.log(`Tokens        ${fmtNum(state.tokens.length)} / 目标 ${fmtNum(cfg.tokenCount)}`);
    const seeded = state.tokens.filter(t => t.holders.length >= cfg.holdersPerToken).length;
    console.log(`已 seed       ${fmtNum(seeded)} / ${fmtNum(state.tokens.length)}（每 token ${cfg.holdersPerToken} holder）`);
  } else {
    console.log(`             (未部署)`);
  }

  console.log('');
  try {
    const block = await publicClient.getBlockNumber();
    const realChainId = await publicClient.getChainId();
    console.log(`链 ID         ${realChainId}（期望 ${cfg.chainId}）`);
    console.log(`当前块号      ${block}`);
  } catch (e) {
    console.error(`❌ RPC 连不上 ${cfg.rpcUrl}: ${explainErr(e)}`);
    process.exit(1);
  }
  if (cfg.deployerKey) {
    const dep = privateKeyToAccount(cfg.deployerKey);
    const bal = await publicClient.getBalance({ address: dep.address });
    console.log(`Deployer      ${dep.address}`);
    console.log(`              ${formatEther(bal)} MAN`);
  }
  if (wallets.length) {
    console.log('');
    console.log(`抽样 5 个钱包余额：`);
    const sample = [];
    for (let i = 0; i < 5; i++) sample.push(wallets[Math.floor(Math.random() * wallets.length)]);
    for (const w of sample) {
      const bal = await publicClient.getBalance({ address: w.address });
      console.log(`  ${w.address}  ${formatEther(bal)} MAN`);
    }
  }
}

// -----------------------------------------------------------------------------
// main
// -----------------------------------------------------------------------------
const handlers = {
  init: cmdInit,
  mint: cmdMint,
  deploy: cmdDeploy,
  'fund-gas': cmdFundGas,
  seed: cmdSeed,
  spam: cmdSpam,
  status: cmdStatus,
};
const cmd = process.argv[2];
const fn = handlers[cmd];
if (!fn) {
  console.error('用法: node tokenspammer.js {init|mint|deploy|fund-gas|seed|spam|status}');
  console.error('');
  console.error('  init                生成 50000 钱包 → wallets-50k.json');
  console.error('  mint [AMOUNT=5000]  通过 LiquidityController mint MAN 给 deployer');
  console.error('  deploy              部署 1 BatchTransfer + 1000 TestERC20，approve max');
  console.error('  fund-gas            给所有钱包打 gas（用 BatchTransfer 一次 200 个）');
  console.error('  seed                每个 token 随机选 500 holder 分发 1e6 token');
  console.error('  spam                高吞吐 ERC-20 互转，目标 1000 TPS（永久跑）');
  console.error('  status              看进度');
  console.error('');
  console.error('推荐流程：build → init → mint → deploy → fund-gas → seed → spam');
  process.exit(1);
}
fn().catch(err => {
  console.error('\n❌ 错误：', explainErr(err));
  if (process.env.DEBUG) console.error(err.stack || err);
  process.exit(1);
});
