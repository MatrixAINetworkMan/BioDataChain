# MAN 刷量机器人

给 Blockscout 制造**持续的、看着像真链**的交易活动。

两套模式，按场景选：

| 模式 | 命令 | 适用 |
| --- | --- | --- |
| **A 拟真**（推荐 demo 用）| `init` → `grow` | 5642 地址按 sigmoid 曲线 24 小时内逐步激活，配合互转 |
| **B 暴力**（看 TPS / 索引压力）| `init` → `fund` → `spam` | 5642 地址瞬间灌满，立刻全速互转 |

## 模式 A — 拟真上线（grow）

5642 个地址不会一秒钟全冒出来——按 **sigmoid 曲线**在 N 小时内逐步激活，
节奏带 **burst 噪音**（不是均匀的 0.07 个/秒，而是"安静一会儿 → 突然来一波 → 再安静"），
看起来就像真用户陆续上链。同时已激活的钱包持续互转。

**推荐 docker 跑（host 不用装 node）**，在 `dev/` 目录下：

```bash
make bot-spam-install      # 一次性，docker 里 npm install（约 30s）
make bot-spam-init         # 生成 5642 钱包到 wallets.json
make bot-grow              # 前台跑（Ctrl+C 退）
```

或后台 daemon 跑（断电自动重启，状态自动续跑）：

```bash
make bot-grow-up           # 起 daemon
make bot-grow-logs         # tail 日志
make bot-grow-status       # 看容器状态
make bot-grow-down         # 停 daemon（active.json 保留）
```

如果本机已经装了 node ≥ 18，也可以直接跑（不走 docker）：

```bash
cd dev/bots/spammer
npm install
npm run init
npm run grow
```

**默认曲线**（5642 地址、24h、sigmoid）：

```
t=0       →  30 个地址在线（bootstrap，立刻打钱让 spam 能跑）
t=6h      →  ~310
t=12h     →  ~2836  ← 增长最快
t=18h     →  ~5360
t=24h     →  ~5642
```

时间轴上每 200 ms 一个 tick，按 `GROWTH_BURST_PROB`（默认 25%）决定要不要激活一波，
单波 1-`GROWTH_BURST_MAX`（默认 5）个，所以画面是：

```
    ▁▁▁ 🌊 ▁▁ 🌊🌊 ▁ 🌊 ▁▁▁ 🌊🌊🌊 ▁ 🌊 ▁▁▁▁
```

互转节奏也跟着激活池规模 ramp：30 个地址时 ~3-9 tps，5642 个时满 3-15 tps。

**可中断重启**：Ctrl+C 后状态存进 `active.json`，下次 `npm run grow` 从同一时间轴继续，
曲线不会跳。想从头来：`make bot-grow-reset`。

## 模式 B — 暴力刷量（fund + spam）

```bash
make bot-spam-install
make bot-spam-init       # 生成 5642 钱包
make bot-spam-fund       # 从 deployer 一次性打钱（瞬间灌满，画面会一眼假）
make bot-spam            # 每秒 3-15 笔互转
```

适合压测前端 / 索引器，不适合做演示截图。

## ⚠️ deployer 余额前提

5642 钱包 × 平均 5100 MAN ≈ **2880 万 MAN**，远超 deployer 的 10000 MAN 创世余额。
脚本 fund / grow 都会 preflight 提示，三种解法：

- **方案 A — 缩小规模试跑**

  ```bash
  WALLET_COUNT=100 FUND_MIN=10 FUND_MAX=50 npm run init
  WALLET_COUNT=100 FUND_MIN=10 FUND_MAX=50 npm run grow
  ```

- **方案 B — 5642 钱包但按余额均分**：把 `FUND_MIN/FUND_MAX` 调到几 MAN 这个量级

- **方案 C — 改 op-deployer intent 把 deployer 创世余额拉高，重建链**

## 环境变量

全部从 `dev/.env` 自动读，可单条覆盖：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `RPC_URL` | `http://localhost:${L2_RPC_PORT}` | L2 RPC，跨机跑就传外网 IP |
| `L2_CHAIN_ID` | — | 必需 |
| `DEPLOYER_PRIVATE_KEY` | — | fund / grow / status 用 |
| `WALLET_COUNT` | 5642 | 钱包数（init / 默认 GROWTH_TARGET）|
| `FUND_MIN` / `FUND_MAX` | 200 / 10000 | 每钱包激活时的随机区间（MAN）|
| `SPAM_MIN` / `SPAM_MAX` | 3 / 15 | 每秒发起的 tx 数；grow 模式按激活池 ramp |
| `SPAM_PCT_MIN` / `SPAM_PCT_MAX` | 0.03 / 0.05 | 每笔转账占余额比例 |
| `GAS_PRICE_GWEI` | 1 | gas tracker ~0.9 gwei，1 必稳 |
| `WALLETS_FILE` | `./wallets.json` | 钱包持久化文件 |
| **grow 专属** | | |
| `GROWTH_DURATION` | 86400 (秒) | 多久把 TARGET 个地址激活完 |
| `GROWTH_INITIAL` | 30 | 启动时立刻激活的种子数（bootstrap）|
| `GROWTH_TARGET` | `WALLET_COUNT` | 最终激活到这个数量 |
| `GROWTH_CURVE` | `sigmoid` | `sigmoid` \| `linear` \| `log` |
| `GROWTH_BURST_PROB` | 0.25 | 每 200ms tick 触发激活 burst 的概率 |
| `GROWTH_BURST_MAX` | 5 | 单次 burst 最多激活几个 |
| `ACTIVE_FILE` | `./active.json` | grow 进度持久化文件 |

调快一点的小例子：1 小时跑完 1000 地址：

```bash
WALLET_COUNT=1000 GROWTH_DURATION=3600 GROWTH_TARGET=1000 npm run grow
```

## 后台跑（已内置 docker daemon 支持）

```bash
make bot-grow-up         # docker 里 -d --restart unless-stopped 跑 grow
make bot-grow-logs       # tail
make bot-grow-down       # 停
```

如果不走 make（直接 docker 命令）：

```bash
docker run -d --init \
  --name mychain-spammer \
  --restart unless-stopped \
  --network mychain-dev \
  -v "$PWD/dev/bots/spammer:/app" -w /app \
  --user $(id -u):$(id -g) -e HOME=/tmp \
  --env-file dev/.env \
  -e RPC_URL=http://op-geth:8545 \
  node:22-alpine \
  node spammer.js grow
```

## 安全 / 注意

- `wallets.json` 含 **5642 个明文私钥**，文件权限 0600，已 `.gitignore`，
  **绝对不要 commit、不要发外网、不要复用到主网**
- `active.json` 不含私钥，但暴露"哪些地址是机器人"，按需保护
- 这玩意只为 **dev / demo / 压测**，别在 prod 跑
