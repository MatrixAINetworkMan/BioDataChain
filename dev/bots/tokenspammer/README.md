# MAN ERC-20 多 token 压测机器人

**目标**：在 L2 链上部署 1000 个 ERC-20，给 50000 个地址灌种子，然后持续在地址间
随机互转这些 token，压测 sequencer / op-geth / blockscout 索引 / 监控链路。

**实测稳态**：~150 TPS（OP Stack op-geth 单线程 EVM + 1s block 当前架构极限，
对标 OP Mainnet ~50、Base ~80、opBNB ~150-300）。
**默认 `TARGET_TPS=200`** = 链 1.3x 速度，长时间稳定运行验证链可靠性。

跟现有 `dev/bots/spammer/`（原生 MAN 互转）正交，不冲突。

## 流程一览

```
build  ─→  init  ─→  mint  ─→  deploy  ─→  fund-gas  ─→  seed  ─→  spam
~1m       ~10s     ~30s     ~10-15min     ~3-5min      ~5-10min   永久
```

| 步骤 | 时间预估 | gas 预估 |
|---|---|---|
| `build` | 1 min | host 0 / docker forge 编译合约 |
| `init` | ~10s | host 0 / 生成 50000 私钥 |
| `mint` | ~30s | LiquidityController mint MAN → deployer |
| `deploy` | ~85s | ~1 MAN / 部署 1 BatchTransfer + 1000 ERC-20 + 1000 approve |
| `fund-gas` | 3-5 min | **~25030 MAN** / 50k 钱包 × 0.5 MAN gas + tx 费 |
| `seed` | 5-10 min | ~80 MAN / 1000 tok × 500 holder × 200/batch = 2500 batch tx |
| `spam` | 永久 | ~30 MAN/小时（按 150 TPS 实测） |
| **合计 mint** | | **30000 MAN** 够初始化 + 几百小时 spam |

> ⚠️ 默认 `make bot-token-mint` 只 mint 5000 MAN（`AMOUNT` 默认值），**远不够 fund-gas 用**。
> 实际跑要 `make bot-token-mint AMOUNT=30000` 或更多。NAL 池有 20 亿 MAN 几乎无限，多 mint 没坏处。

## 推荐用法（Makefile 一条龙）

在 `dev/` 目录下：

```bash
# 0. 装依赖（docker 里 npm install + forge build），一次性
make bot-token-install      # 装 viem
make bot-token-build        # forge 编译合约 → artifacts.json

# 1. 准备
make bot-token-init                       # 50000 钱包
make bot-token-mint AMOUNT=30000          # mint 30000 MAN 给 deployer（默认 5000 不够）

# 2. 上链（部署 + 灌种子）
make bot-token-deploy       # 部署 1000 ERC-20 + BatchTransfer + approve
make bot-token-fund-gas     # 给 50000 钱包打 0.5 MAN gas 费
make bot-token-seed         # 每 token 随机选 500 holder 分发

# 3. 开打
make bot-token-spam-up      # 后台 daemon 跑 spam（restart unless-stopped）
make bot-token-spam-logs    # tail 日志看 TPS
```

任何阶段：

```bash
make bot-token-status       # 看进度（钱包数 / token 数 / seed 进度 / 链高）
make bot-token-spam-down    # 停 daemon
```

## TPS 期望值

链配置：`L2_GAS_LIMIT=100000000`、`L2_BLOCK_TIME=3s`、op-rbuilder sequencer + op-geth follower。

### 实测瓶颈定位（2026-04 数据）

跑 `TARGET_TPS=1000` 时：
- 前 ~8s：mempool 缓冲，spammer 显示 800-1000 TPS（虚高，实际是缓冲）
- mempool 触顶后：链消化速度 = **真实 TPS = 100-150**
- block utilization 仅 5-10%（远未到 EVM 极限），CPU 50%/核（远未到算力极限）

→ 瓶颈在 OP Stack op-geth 的 sequencer 行为：每 block 一次性 fillTransactions
拿当时 mempool 的 ~100 笔，剩下 800ms 闲着等 op-node 来取 payload。
新到的 tx 进不了当前 block，要等下一个。

### 默认 `TARGET_TPS=200` 的合理性

| 模式 | spammer 输出 | 链消化 | mempool 行为 |
|---|---|---|---|
| `TARGET_TPS=150` | 150 | 150 | mempool 几乎 0，没压力 |
| **`TARGET_TPS=200`（默认）** | 200 | 150 | 净增 50/s，HIGH=3000 大约 60s 触发，**长时间稳定** |
| `TARGET_TPS=300` | 300 | 150 | 净增 150/s，HIGH 大约 20s 触发，**周期性 backpressure** |
| `TARGET_TPS=1000` | 1000 | 150 | mempool 雪崩，必须开 backpressure |

200 TPS 是"温和过载"：spammer 持续给链压力，但 backpressure 不频繁触发，
适合长时间（几小时～几天）稳定性测试。想看 backpressure 周期性行为用 300+。

### 想冲峰值（学术目的）

```bash
TARGET_TPS=1000 MEMPOOL_BACKPRESSURE=0 make bot-token-spam-up
```

会看到前 8 秒 ~1000 TPS（mempool 缓冲），之后链 TPS 退化到 ~50-100 TPS（mempool
雪崩，op-geth 在 10000+ pending 下 selection 退化）。仅适合短时观察。

### 想突破 150 TPS sustained（要做架构改动）

| 方案 | 预期 | 投入 |
|---|---|---|
| `L2_BLOCK_TIME=2s` 重建链 | 250-300 TPS | 半小时 |
| `BatchTransfer` 合约（1 tx 含 100 transfer） | 名义 150 TPS / transfer 量 15000/s | 半天 |
| 换 op-reth 替代 op-geth | 600-1500 TPS | 1-2 周 |
| patch op-geth worker 增量 fill | 800-1500 TPS | 1 周 |

### fail-fast 模式（验证超载不雪崩）

链稳态 ~100-150 TPS 时，如果业务方目标是"测 200 TPS 时链不雪崩 / RPC 不奶 / client 能感知"，
不需要任何架构改动：

```bash
# 1) 改 op-geth：把 mempool 调小到 200 slots，触发即时 reject
echo 'OP_GETH_TXPOOL_GLOBALSLOTS=200'  >> .env
echo 'OP_GETH_TXPOOL_ACCOUNTSLOTS=4'   >> .env
docker compose up -d --force-recreate op-geth

# 2) spammer 关 backpressure、固定 200 TPS（一键 target）
make bot-token-spam-failfast
```

行为：
- 链层每秒消化 ~100 tx 进 block，mempool 维持在 0-200 之间
- 多余的 ~100 tx/s 在 RPC 层立即拿到 `txpool is full` 错误
- spammer report 里出现 `fail{full=...,nonce=...,other=...}` 分类计数
- 链不雪崩、RPC 端口持续可用、client 能区分降级 vs 正常失败

详见 `docs/STRESS_TEST_REPORT.md` §13。

## 文件说明

| 文件 | 内容 | git 跟踪？ |
|---|---|---|
| `tokenspammer.js` | 主脚本 | ✅ |
| `build.sh` | docker forge 编译 | ✅ |
| `package.json` | npm 依赖 | ✅ |
| `contracts/*.sol` | TestERC20 + BatchTransfer 源码 | ✅ |
| `contracts/foundry.toml` | forge 配置 | ✅ |
| `contracts/out/` | forge 编译产出（abi + bytecode） | ❌（build 生成）|
| `wallets-50k.json` | 50000 钱包私钥（明文，~9MB，mode 0600） | ❌ |
| `tokens.json` | 1000 token 地址 + holder 索引 | ❌ |
| `node_modules/` | npm | ❌ |

⚠️ **`wallets-50k.json` 含 50000 个明文私钥，绝对不要 commit / 不要发外网 / 不要复用主网。仅 dev / 压测用。**

## 环境变量调优

全部从 `dev/.env` 自动读，可单条覆盖。

### RPC 端点

| 变量 | 默认 | 说明 |
|---|---|---|
| `RPC_URL` | `http://op-geth:8545` | **通用** RPC：链 metadata、deploy/mint/seed/fund-gas、status |
| `SPAM_RPC_URL` | `= RPC_URL` | **spam** 子命令发 `eth_sendRawTransaction` 的端点 |
| `DIAG_RPC_URL` | `= SPAM_RPC_URL` | **mempool 监控**（backpressure）的端点 |

为什么分三个：

- **当前**（op-geth 单 sequencer）：三个都指 op-geth，老配置兼容
- **接 Flashblocks 后**（op-rbuilder 是真正出块的 sequencer EL）：
  - `RPC_URL` 仍然可以保留指 op-geth（一次性命令对端点不敏感）
  - `SPAM_RPC_URL` 必须改成 op-rbuilder —— 否则 tx 进 op-geth mempool 但
    op-rbuilder 看不到，要等 mempool rebroadcaster 同步过来已经过几个 block window
  - `DIAG_RPC_URL` 也要指 op-rbuilder —— backpressure 必须看真实出块的 mempool

Makefile 端：`bot-token-*` 目标里的 RPC 端点由 `L2_RPC_URL_INTERNAL` /
`SPAM_RPC_URL_INTERNAL` / `DIAG_RPC_URL_INTERNAL` 控制（在 `.env` 里覆盖）。

### 业务参数

| 变量 | 默认 | 说明 |
|---|---|---|
| `WALLET_COUNT` | 50000 | 钱包总数 |
| `TOKEN_COUNT` | 1000 | ERC-20 token 数量 |
| `HOLDERS_PER_TOKEN` | 500 | 每个 token 的初始持有者数 |
| `FUND_GAS_AMOUNT` | 0.5 | 每钱包 gas 储备（MAN） |
| `FUND_BATCH_SIZE` | 200 | batchSendNative 单 tx 多少接收人 |
| `SEED_BATCH_SIZE` | 200 | batchTransferFrom 单 tx 多少接收人 |
| `SEED_AMOUNT` | 1000000 | 每 holder 拿到多少 token（1e6） |
| `TOKEN_INITIAL_SUPPLY` | 1000000000 | 每 token 总发行量（1e9） |
| `SPAM_AMOUNT_WEI` | 1e15 | 每笔 spam 转账金额（wei，= 0.001 token） |
| `TARGET_TPS` | **200** | 目标 TPS（链稳态 ~150，设 200 = 1.3x 温和过载长跑） |
| `SPAM_TICK_MS` | 100 | spam tick 间隔（100ms × 20 笔 = 200 TPS） |
| `MAX_TICK_QUEUE` | **8** | 同时在路上的 RPC batch 数。200 TPS 节奏 8 够用，冲峰值用 16-32 |
| `HTTP_CONNECTIONS` | 64 | undici 全局 HTTP 连接池上限（默认 10 是单 host 瓶颈） |
| `MEMPOOL_BACKPRESSURE` | 1 | **重要**：spammer 自动监控 mempool，pending+queued ≥ HIGH 暂停，≤ LOW 恢复。防止 mempool 涨到 1w+ 触发 op-geth sequencer 选 tx 退化（雪崩）。 |
| `MEMPOOL_HIGH_WATER` | **3000** | mempool 总量到此停发（链 ~150 TPS，3000 ≈ 20s buffer） |
| `MEMPOOL_LOW_WATER` | **1000** | mempool 降到此恢复 |
| `MEMPOOL_CHECK_MS` | 2000 | 多久查一次 mempool |
| `MAX_FEE_GWEI` / `PRIORITY_FEE_GWEI` | 50 / 1 | EIP-1559 价格上限 |

> **重要：op-geth 也要调过参数才能跑 1000 TPS**。我们已经在 `dev/docker-compose.yml`
> 里给 op-geth 加了 `--txpool.globalslots=20000 --txpool.accountslots=128` 等。
> 用旧 docker-compose 启的链 mempool 会秒满（geth 默认 4096 slots / 16 per-account）。
> 拉新代码后 `make dev-down && make dev-up` 才能让 op-geth 用新参数。

小规模试跑（先验证流程通）：

```bash
WALLET_COUNT=500 TOKEN_COUNT=10 HOLDERS_PER_TOKEN=50 \
  make bot-token-init bot-token-deploy bot-token-fund-gas bot-token-seed
TARGET_TPS=100 make bot-token-spam-up
```

## 高吞吐设计要点

spammer 客户端能跑到 1000+ TPS（瞬时），实际持续 TPS 看链消化：

1. **JSON-RPC batch**：每个 100ms tick 把 20 个 `eth_sendRawTransaction` 打进
   一个 HTTP 请求一次发出，复用 keep-alive socket，省 99% HTTP/parse 开销。
2. **undici 全局连接池 64**：node 默认每个 origin 只开 ~10 conn，spam 场景下
   并发 batch 会把连接打满，sendRawTransaction 回包变成串行 → 实测 200 TPS
   卡死。脚本启动时 `setGlobalDispatcher` 把单 host 连接数提到 64。
3. **本地 nonce 跟踪**：`senderState[i].nonce` 数组，签名时 `nonce++`，
   失败时按需从 RPC 同步。不每笔都查 nonce。
4. **busy 标志位**：`Uint8Array(50000)` 标记当前在飞的 sender，避免
   同一 nonce 被两笔 tx 占用（同 tick 内已用 set 排除，跨 tick 用 busy）。
5. **预编 transfer calldata**：直接拼 `0xa9059cbb + to + amount`，不走
   viem 的 abi encode 重路径（每笔省 ~50us）。
6. **背压**：`MAX_TICK_QUEUE`，前面 tick 还在 RPC 飞就跳过新 tick，
   防止 setInterval 堆积导致 nonce / busy 状态错乱。
7. **mempool 背压**：监控 op-geth `txpool_status`，pending+queued ≥ HIGH 暂停，
   ≤ LOW 恢复。这是面对慢链（如当前 150 TPS）的优雅降级关键。
8. **报告含 RPC p50/p95/max 延迟**：能看出 op-geth 处理批次的真实速度。
   p50 > 200ms 说明 op-geth 在喘；p50 < 50ms 说明链还能加压。

## 常见问题

### Q: TPS 上不去？看 spam 日志

```
[   30s] ok=    7,500 fail=      0 tps(rec)=  0 tps(avg)= 248 q=8/8 rpc(p50/p95/max)=4500/12000/18000ms
```

读这一行：

- `q=8/8` → 并发批次满载，spammer 在等 op-geth 回包。
- `rpc p50=4500ms` → 单批 RPC 来回 4.5 秒，**op-geth 是瓶颈**：
  - 检查 op-geth CPU：`docker stats mychain-op-geth --no-stream`，超过 200% 说明多核都满了。
  - 检查 mempool：`make logs-op-geth | grep -i 'txpool\|drop\|full'`，可能 GlobalSlots 满了。
  - 检查 sequencer block 包装：blockscout 看每块 tx 数，若长期 < 200 → sequencer 出块慢。
- `rpc p50=20ms` 但 `tps(rec)=0` → 客户端瓶颈，加 `MAX_TICK_QUEUE=16`。

调参快速对照：

| 症状 | 调整 |
|---|---|
| `q=8/8` 长期满 + `rpc p50 > 2000ms` | op-geth 锁竞争严重，**调小** `MAX_TICK_QUEUE=4` 或扩 op-geth CPU |
| `q < 4` + `tps(rec) < target` | 客户端发不够，加 `MAX_TICK_QUEUE=16` |
| `fail` 比例高（>5%）+ "txpool full" 日志 | mempool 满，op-geth 加 `--txpool.globalslots=40000` |
| `fail` 含 "account too many txs" | 账户 pending 超 128，加 `--txpool.accountslots=256` |
| 链上块大小很不均匀（1, 200, 1, 162...） | sequencer 出块抖动，跟 archive mode + state.scheme=hash 有关 |

### Q: 链本身的 TPS 上限多少？

实测稳态 **~150 TPS**。瓶颈是 OP Stack op-geth 在 sequencer 模式下的 worker 行为：
每 block 一次性 fillTransactions 拿当时 mempool 的 ~100 笔，剩下 800ms 闲着等
op-node 来取 payload，新到的 tx 进不了当前 block。

由 op-geth 的 `OP_GETH_GCMODE` 和 `OP_GETH_STATE_SCHEME` 决定（在 `dev/.env`）：

| 配置 | 实测上限 | 适合 |
|---|---|---|
| `archive + hash`（旧默认） | 30-80 TPS | 调试，能查任意历史块 state |
| **`full + path`（新默认）** | **120-180 TPS** | 压测、跑流量 |

切配置必须重建链：

```bash
# .env 改 OP_GETH_GCMODE / OP_GETH_STATE_SCHEME
make dev-restart    # 链上数据全丢
# 然后 tokenspammer 全套要重来：init → mint → deploy → fund-gas → seed → spam
```

也跟硬件有关：

- **磁盘**：NVMe SSD（随机写 IOPS ≥ 5k 即可，因为 sequencer 不是 IO bound）
- **CPU**：4 核+。op-geth 单线程 EVM，跑满也只用 ~2 核，多核帮助有限
- **内存**：16GB 够，op-geth `--cache=8192` 已开

### Q: 行业对标

| 链 | 架构 | 持续 TPS |
|---|---|---|
| OP Mainnet | OP Stack + op-geth (2s block) | ~50 |
| Base | OP Stack + op-geth (2s block) | ~80（峰值 700，sequencer 限速） |
| opBNB | OP Stack + op-geth (1s block) | 150-300 |
| **本链** | OP Stack + op-geth (1s block) | **~150** |

**~150 TPS 在 OP Stack 同架构里是中位数水平**。要稳定 1000+ TPS 需要 reth 或并行 EVM 等架构改造。

### Q: 怎么看链上真实 TPS（不是 spammer 报告）？

```bash
make bot-token-chain-tps      # 最近 10 个块的 tx 数 + 利用率
make bot-token-mempool        # mempool pending/queued
make bot-token-geth-stats     # op-geth CPU/mem/IO
```

如果 `chain-tps` 显示的 TPS << spammer 报告的 `tps(avg)`，说明 spammer 提交的 tx
在 mempool 排队，链来不及打包 → 链是瓶颈，不是 spammer。

### Q: 跑到一半失败率飙升？

通常是 sequencer mempool 满了。看 `make logs-op-geth` 有没有 `txpool full`。
解决：减小 `TARGET_TPS` 或调小 `MAX_TICK_QUEUE`。

### Q: deployer 余额不够？

```bash
make bot-token-mint AMOUNT=10000   # 再 mint 10000 MAN
```

NAL 池有 2e9 MAN，几乎无限。

### Q: 重启 spam 后前几秒大量 nonce 错误？

正常。spam 启动时一次性批拉 nonce，但 daemon 重启之间链可能继续出块，
nonce 状态不一致。失败的 tx 会触发 RPC 重新同步，~10 秒内自愈。

### Q: 想清掉所有状态重头来？

```bash
make bot-token-clean        # 删 wallets / tokens / artifacts / node_modules
```

⚠️ 删 `tokens.json` 后，链上的 1000 个 token 还在，但 spammer 不知道地址了。
要么自己保留 backup，要么重新 deploy 一批新 token。
