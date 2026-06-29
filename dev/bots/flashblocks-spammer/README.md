# flashblocks-spammer

通过 op-rbuilder 的 `eth_sendBundle` 发交易，专门用来压测 OP Stack + Flashblocks
的 TPS 上限。配套 `feat/high-tps-flashblocks` 分支的 Phase 1 实证。

## 为什么不能复用 tokenspammer？

主链 main 用 `eth_sendRawTransaction` 发到 op-geth 的 mempool 等 sequencer 打包。

Flashblocks 架构里：
- **op-rbuilder 是 builder**（不是 sequencer），有自己的 mempool
- **op-geth 退化为 fallback**，user tx 到这里会卡在 pending（rollup-boost 优先选 op-rbuilder 的 payload）
- builder-playground 的 P2P gossip **不能可靠**地把 op-geth 的 mempool 同步给 op-rbuilder
- 唯一稳定路径：dApp 自己用 `eth_sendBundle` **直接**把 tx 发给 op-rbuilder

详见 `docs/HIGH_TPS_RESEARCH.md` § 6.2 决策记录。

## 用法

### 0. 前置（chain-test2 / builder-playground 已起好）

宿主机不需要装 node/npm，全部走 docker（`node:20-alpine` ~ 50MB）。

### 1. 跑单档（推荐先跑 100 TPS smoke test）

```bash
cd /data/code/mychain/dev/bots/flashblocks-spammer

# 第一次跑会自动 npm install 到宿主 node_modules
docker run --rm -v "$(pwd)":/app -w /app node:20-alpine npm install

# 100 TPS / 50 senders / 60s
docker run --rm --network host -v "$(pwd)":/app -w /app \
  -e TARGET_TPS=100 -e N_SENDERS=50 -e DURATION_S=60 \
  node:20-alpine node spammer.js
```

### 2. 跑阶梯（找拐点）

封装成 `ladder.sh`，自动跑多档 + 抽取关键指标：

```bash
# 默认 100/300/500/1000 TPS 各 60s
bash ladder.sh

# 自定义档位
STEPS="200 400 600 800" DURATION_S=120 bash ladder.sh
```

输出：
- `logs/ladder-<时间戳>/tps-NNN.log`：每档完整日志
- `logs/ladder-<时间戳>/summary.txt`：抽取的关键指标对比表

### 3. 自定义跑（直接调 spammer.js）

```bash
docker run --rm --network host -v "$(pwd)":/app -w /app \
  -e TARGET_TPS=300 -e N_SENDERS=100 -e DURATION_S=120 \
  node:20-alpine node spammer.js
```

### 3. 完整环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `RPC_URL` | `http://127.0.0.1:8547` | op-rbuilder 的 user RPC（接 `eth_sendBundle`）|
| `READ_RPC_URL` | `http://127.0.0.1:8548` | flashblocks-rpc（用于读 head/balance/nonce）|
| `FUNDER_KEY` | Anvil[1] | 给所有 sender 注资的私钥；必须 prefunded 且没人抢 nonce |
| `CHAIN_ID` | `13` | builder-playground OP L2 默认 chainId |
| `TARGET_TPS` | `100` | 目标每秒 bundle 数（每个 bundle 1 笔 tx）|
| `N_SENDERS` | `50` | 临时 EOA 数（每个独立 nonce）|
| `DURATION_S` | `60` | spam 持续秒数 |
| `FUNDING_ETH` | `1` | 每个 sender 注资多少 ETH（够发 ~50000 笔 transfer）|
| `BUNDLE_BLOCK_OFS` | `1` | bundle.blockNumber = head + N（1 = 下一个 block）|
| `GAS_PRICE_GWEI` | `1` | maxFeePerGas / maxPriorityFeePerGas（Gwei）|
| `REPORT_INTERVAL_S` | `5` | 每隔几秒打一次进度 |

## 输出解读

### 阶段日志

```
[setup] funder=0x70997970...79C8
[setup] generating 50 ephemeral senders, funding 1 ETH each
[setup] funder balance=2475...  nonce=1  head=61500
[setup] signed 50 funding txs
[setup] sending funding bundle to op-rbuilder, target block=61501
[setup] funding bundle accepted: { bundleHash: "0x..." }
[setup] all senders funded after 2s
[spam] target_tps=100  n_senders=50  duration=60s
[+5s] head=61506  rate sent=100/s ok=100/s err=0/s | total sent=500 ok=500 err=0
[+10s] head=61511  rate sent=100/s ok=100/s err=0/s | total sent=1000 ok=1000 err=0
...
```

### 最终报告（关键指标）

```
========== FINAL REPORT ==========
bundles sent:  6000
bundles ok:    5980
bundles err:   20
error rate:    0.3%
rpc lat (ms): p50=2 p95=8 p99=20 max=150

--- on-chain measurement (last 30 blocks) ---
total txs (30 blocks): 5840  approx chain TPS: 194.7
user  txs (30 blocks): 5750  approx user  TPS: 191.7
max txs in single block: 220
sender[0] on-chain nonce: 119 (sent locally: 120)
```

**核心评估**：
- `user TPS` ≈ `TARGET_TPS` → builder 顺利 inclusion，链能撑这个 TPS
- `sender[0] nonce ≈ sent` → 单 sender 也没卡，没 nonce drift
- `error rate < 5%` → 健康；> 20% 说明 builder mempool 已饱和

## 调优旋钮

| 现象 | 调整 |
|---|---|
| `user TPS << TARGET_TPS`，`bundle ok` 高 | builder 收到了但没打包：调大 block gas limit / 减 BUNDLE_BLOCK_OFS |
| `error: bundle simulation failed` | sender 余额不够，加大 `FUNDING_ETH` 或 `N_SENDERS` |
| `error: nonce too low` | 单 sender 发太快，增大 `N_SENDERS` 分散 |
| `rpc lat p99 > 200ms` | RPC 转发瓶颈：考虑直连 op-rbuilder 容器内网（避免 host 端口转发）|

## 已知限制

1. **每个 bundle 只 1 笔 tx**：高 TPS 时 RPC 调用密度大，但语义清晰。如果要测试
   bundle 多 tx 模式，改 `buildAndSendOne` 把多笔 sign 后 push 进同一个 bundle。
2. **funder 一次性注资**：所有 sender 来自单个 funder 的连续 nonce，所以 `FUNDER_KEY`
   绝不能跟 builder 的 `--rollup.builder-secret-key` 同地址（builder 自己每秒发
   attestation tx 占 nonce）。Anvil[1] 是 builder-playground 默认 prefunded 但
   builder 不用的账户，最佳选择。
3. **不支持 ERC-20**：spammer 只发原生 ETH transfer。后期接入 mychain 的 ERC-20
   时，复用 tokenspammer 的合约部署 + nonce 管理逻辑。

## 与 tokenspammer 的对比

| 维度 | tokenspammer (main) | flashblocks-spammer (本工具) |
|---|---|---|
| 目标链 | mychain v6 (op-geth sequencer) | OP Stack + Flashblocks |
| 入口 | `eth_sendRawTransaction` → op-geth | `eth_sendBundle` → op-rbuilder |
| 交易类型 | ERC-20 transfer（1000 token 池）| 原生 ETH transfer（最简）|
| 钱包 | 50000 持久 EOA | 50 临时 EOA（每跑一次重新生成）|
| 失败语义 | nonce / pool full / fund 三类 | bundle accept / reject |
| 用途 | 长期稳定性 + SLA 验证 | 短期 TPS 上限探测 |

## 下一步（路线图）

- ✅ Phase 1.3：本工具跑 100 / 300 / 500 TPS，记录 builder 拐点
- ⏳ Phase 2.1：把 ERC-20 transfer 接进来，跑跟 main 对照的 stress-soak
- ⏳ Phase 2.2：写 mychain 的 **bundle proxy** —— 让 dApp 透明地用 `eth_sendRawTransaction`
  我们后端转成 `eth_sendBundle` 发给 builder
