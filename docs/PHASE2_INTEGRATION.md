# Phase 2 全栈集成设计（mychain v7）

> **状态**: 设计阶段，未实施。本 doc 是 review 入口；模块详细设计见 `PHASE2_BUNDLE_PROXY.md`。
> **关联**: `HIGH_TPS_RESEARCH.md`（Phase 1 结论）、`PHASE2_BUNDLE_PROXY.md`（bundle-proxy 模块）
> **目标**: dev/chain-test2 上跑通 v7 完整 stack（anvil + op-geth + op-rbuilder + rollup-boost + bundle-proxy + Blockscout 适配），与 v6 chain-test 双轨并存验证。

> **⚠️ v7.0 实施调整（2026-05-11）**：
> 原计划的 `flashbots/flashblocks-rpc` 独立 image 经实测已 **10 个月未更新**（最新 tag `sha-7caffb9`，
> 与 op-rbuilder 0.3.x 协议不兼容）。**v7.0 临时放进 docker-compose `flashblocks-rpc` profile 默认不起**，
> Blockscout 与 bundle-proxy 的读路径都退回到 `op-geth`（finalized 视图，稳）。
> Pre-confirmation 视图作为 **v7.1 工作项**，用 `base/node-reth` 风格的 reth fork 替代。
> 决策 D3（Blockscout 指 flashblocks-rpc）暂时降级为 D3'（指 op-geth），文档保留原计划备查。

---

## 0. 决策摘要（业务方拍板的 5 个全栈决策）

| # | 决策 | 选定 | v7.0 实际落地 | 理由 |
|---|---|---|---|---|
| D1 | L1 用什么 | **anvil（保持）** | ✅ 同设计 | dev 阶段零成本；Sepolia 等业务流压稳后再换 |
| D2 | op-geth 角色 | **保留作 sequencer + fallback** | ✅ 同设计 | op-rbuilder 挂掉自动回退到 v6 baseline 180 TPS |
| D3 | Blockscout indexer 指向 | **flashblocks-rpc**（force_d3b）| ⚠️ **临时改 op-geth**（独立 image 已废弃，v7.1 用 base/node-reth 重做） | reorg 风险已知，但上游 image 不可用 |
| D4 | mychain dev state | **v6/v7 双链并存** | ✅ 同设计 | v6 chainId=42170 留 chain-test，v7 chainId=**175700** 起 chain-test2 |
| D5 | 实施顺序 | **并行**（设计 doc + compose + bundle-proxy + Blockscout 同步推进）| ✅ 同设计 | 缩短临界路径 |

---

## 1. 拓扑全景（v6 vs v7）

### 1.1 v6 baseline（chain-test，main 分支，不动）

```
                  ┌──────────────┐
[dApp / SDK]      │ Blockscout   │ ───┐
   │              └──────────────┘    │ index http://op-geth:8545
   │ eth_sendRawTransaction           │
   ▼                                  ▼
[op-geth :8545]──── txpool fail-fast (globalslots=500)
   │ Engine API
   ▼
[op-node] → [op-batcher] → [L1 anvil]
```

稳态 180 TPS，攻击场景 mempool 丢 tx 但链不雪崩。

### 1.2 v7 target（chain-test2，新分支 `feat/phase2-flashblocks`）

```
                                    ┌────────────────────────┐
[dApp / SDK]   ──────────────► [bundle-proxy :9560]          │
   │ eth_sendRawTransaction         │ eth_sendBundle         │
   │                                ▼                        │
   │                          [op-rbuilder :9550]            │
   │                                │ Engine API             │
   │                                ▼                        │
   │                          [rollup-boost :9555]           │
   │                                │ Engine API             │
   │                                ▼                        │
   │                          [op-node :9547]                │
   │                                │ Engine API ⏎          │
   │                                ▼                        │
   │                          [op-geth :9545]   ←────────────┘  fallback
   │                                │ (sequencer 角色)            (rbuilder 挂时直连)
   │                                ▼
   │                          [op-batcher] → [L1 anvil :8545]
   │
   │       eth_call / receipts ▾
   └─────────► [flashblocks-rpc :9548]  ← read replica，pre-confirmation 视图
                       ▲
                       │ index? (见 §6 决策)
                  ┌────┴───────┐
                  │ Blockscout │
                  │ :4000      │
                  └────────────┘
```

**关键变化点（5 个）**：
1. **新增 4 个容器**：`op-rbuilder`、`rollup-boost`、`flashblocks-rpc`、`bundle-proxy`。
2. **op-node 改 `--l2`**：从 `http://op-geth:8551` 改成 `http://rollup-boost:8551`（rollup-boost 是 op-node 与 op-rbuilder/op-geth 之间的 dispatch 层）。
3. **op-batcher 不变**：`--l2-eth-rpc=http://op-geth:8545` 继续指 op-geth（因为 batcher 要 final state，不要 pre-confirmation）。
4. **dApp 入口改成 bundle-proxy :9560**（dev `.env` 的 `L2_RPC_URL` 改这个，其他 RPC 端口保留）。
5. **Blockscout indexer 指向**：见 §6 详细折中。

---

## 2. 完整端口表

> v6 chain-test 与 v7 chain-test2 在不同物理机，**端口不冲突**。但为防未来 v6+v7 同机部署，v7 新增容器全部用未占用端口。

### 2.1 host 端口分配

| 服务 | 容器 | host 端口 | 说明 |
|---|---|---|---|
| anvil (L1) | mychain-anvil | 8545 | v6/v7 复用，chainId=901 |
| **op-geth (sequencer)** | mychain-op-geth | **9545** (RPC) / **9546** (WS) | v6/v7 复用，chainId=175700 (v7) |
| op-node | mychain-op-node | 9547 | v6/v7 复用 |
| op-batcher | mychain-op-batcher | 内部端口 | 不暴露 |
| **op-rbuilder** ⭐ 新 | mychain-op-rbuilder | **9550** (RPC) / **9551** (WS) | v7 only |
| **rollup-boost** ⭐ 新 | mychain-rollup-boost | **9555** (engine) / **9556** (debug) | v7 only |
| **flashblocks-rpc** ⭐ 新 | mychain-flashblocks-rpc | **9548** (RPC) | v7 only，read replica |
| **bundle-proxy** ⭐ 新 | mychain-bundle-proxy | **9560** (RPC) / **9561** (metrics) | v7 only，dApp 入口 |
| Blockscout frontend | mychain-blockscout-frontend | 4000 | v6/v7 复用（不同 stack 起一份）|
| Blockscout API | mychain-blockscout-backend | 4001 | 同上 |
| Blockscout stats | mychain-blockscout-stats | 4002 | 同上 |
| Grafana | mychain-grafana | 3000 | 已有 |
| Prometheus | mychain-prometheus | 9090 | 已有 |

### 2.2 容器内 → 容器内（service discovery）

| 调用方 | 被调用 | URL（容器名解析）| 协议 |
|---|---|---|---|
| op-node | rollup-boost | `http://rollup-boost:8551` | engine API (JWT) |
| rollup-boost | op-rbuilder | `http://op-rbuilder:8551` | engine API (JWT) |
| rollup-boost | op-geth | `http://op-geth:8551` | engine API (JWT) |
| op-rbuilder | flashblocks-rpc | `ws://flashblocks-rpc:8546` | sub-flashblock stream |
| flashblocks-rpc | op-geth | `http://op-geth:8545` | finality follow |
| bundle-proxy | op-rbuilder | `http://op-rbuilder:8545` | eth_sendBundle |
| bundle-proxy | op-geth | `http://op-geth:8545` | fallback raw tx |
| op-batcher | op-geth | `http://op-geth:8545` | 不变 |
| Blockscout backend | flashblocks-rpc / op-geth | 见 §6 决策 | indexer |

---

## 3. chainId 与 dev state 隔离

### 3.1 v7 chainId

- **L1**: `901`（同 v6，anvil 不变）
- **L2**: `175700`（业务方指定）

为什么改：业务方钱包同时连 v6/v7 时，相同 chainId 但不同合约地址会让 MetaMask 缓存炸（"You're connected to a different network than expected"）。改 chainId = 钱包内独立配置，业务方双轨切流量更安全。

实测核对：175700 在 [chainlist.org](https://chainlist.org/) 无注册（2026-05-09 查），不撞已知公链/L2。

### 3.2 mychain v6/v7 双 stack 共存方案

| 资源 | v6 (chain-test) | v7 (chain-test2) |
|---|---|---|
| 物理机 | 现有 chain-test | chain-test2 |
| 分支 | main | `feat/phase2-flashblocks`（新建）|
| L2 chainId | 42170 | 175700 |
| 合约 deploy | 现有 | fresh deploy 50k 钱包 + 1000 token |
| Blockscout DB | 现有 | 独立 volume（首次 1-2 分钟 index）|
| 业务方接入 | RPC = chain-test:9545 | RPC = chain-test2:**9560** ← bundle-proxy |
| 切流量方式 | 钱包切网络 | 同 |

### 3.3 一旦 v7 稳定，v6 retire 时机

> 不在本 PR 范围。**v7 业务方 sign-off + 7 天 0 incident 之后**，再决定 v6 是否下线。dev 环境保留 v6 至少 30 天作为对照基线。

---

## 4. 启动顺序（v7 dev-up）

容器依赖关系（docker-compose `depends_on` + healthcheck）：

```
1. anvil (L1)               healthcheck: cast block-number
   ↓
2. op-deployer (一次性)      profile=deploy
   ↓
3. op-geth-init (一次性)     profile=deploy
   ↓
4. op-geth (sequencer)       healthcheck: eth_blockNumber
   ↓
5. op-rbuilder ⭐            healthcheck: eth_chainId
   ↓
6. rollup-boost ⭐           healthcheck: GET /healthz
   ↓
7. op-node                   --l2=http://rollup-boost:8551 ← 改了
   healthcheck: optimism_syncStatus
   ↓
8. op-batcher                不变
   ↓
9. flashblocks-rpc ⭐        depends_on: op-rbuilder（订阅 sub-flashblock stream）
   ↓
10. bundle-proxy ⭐          depends_on: op-rbuilder + op-geth（fallback target）
   ↓
11. Blockscout (8 容器)      独立 compose，indexer 指 §6 决策的 RPC
```

**关键陷阱**：op-node 必须等 rollup-boost healthy。rollup-boost 必须等 op-rbuilder + op-geth 同时 healthy（否则 fallback 链路没有 backup）。

---

## 5. Makefile 扩展（不破坏 v6 现有流程）

新增 target（v6 现有 target 全保留）：

```
make dev-up                  ← v6 行为，不变
make dev-up-with-explorer    ← v6 行为，不变
make dev-clean               ← v6 行为，不变

make flashblocks-up          ⭐ 新：拉起 v7 stack（要先 dev-up 起 anvil + op-geth）
make flashblocks-down        ⭐ 新：停 v7 新增容器，保留 v6
make flashblocks-status      ⭐ 新：查 op-rbuilder/rollup-boost/flashblocks-rpc/bundle-proxy
make flashblocks-logs        ⭐ 新：tail 4 个新容器
make flashblocks-clean       ⭐ 新：删 v7 容器 + volume

make dev-up-flashblocks      ⭐ 新：dev-up + flashblocks-up 一键（推荐 chain-test2 用）
make blockscout-up-flashblocks ⭐ 新：Blockscout 指向 §6 决策的 RPC
```

**实现策略**: 用 `docker-compose.flashblocks.yml` 作为 override，复用主 `docker-compose.yml`。命令拼接 `-f docker-compose.yml -f docker-compose.flashblocks.yml`。

---

## 6. Blockscout 适配（D3=force_d3b：M2 直接指 flashblocks-rpc）

### 6.1 决策与已知风险

业务方拍板 **D3=force_d3b**：M2 阶段 Blockscout indexer 直接指 `flashblocks-rpc:8545`，不延后。

**已知风险（reorg）**：flashblocks-rpc 是 pre-confirmation 视图，每 250ms 收 builder 的 sub-flashblock，理论上可被 sequencer 的 finalized chain 推翻。Blockscout indexer 有 reorg 处理（`INDEXER_BLOCK_FETCHER` mark non_canonical），但频繁 reorg 会让：

- ❌ frontend 显示 tx → 数秒后 tx 消失
- ❌ stats 微服务 daily counter 错乱
- ❌ DB 写放大

### 6.2 实施配置

`dev/blockscout/envs/backend.env.tpl` 参数化 RPC 端点：

```
ETHEREUM_JSONRPC_HTTP_URL=${BLOCKSCOUT_INDEXER_RPC:-http://op-geth:8545}
ETHEREUM_JSONRPC_TRACE_URL=${BLOCKSCOUT_INDEXER_TRACE_RPC:-http://op-geth:8545}
ETHEREUM_JSONRPC_WS_URL=${BLOCKSCOUT_INDEXER_WS:-ws://op-geth:8546}

# Blockscout 内置 reorg detection（默认开），M2 我们再调激进一点：
INDEXER_DISABLE_INTERNAL_TRANSACTIONS_FETCHER=false
INDEXER_FETCHER_INIT_QUERY_LIMIT=500
INDEXER_BLOCK_REWARD_FETCHER_BATCH_SIZE=10
```

`dev/.env.flashblocks` 设：

```
BLOCKSCOUT_INDEXER_RPC=http://flashblocks-rpc:8545
BLOCKSCOUT_INDEXER_TRACE_RPC=http://op-geth:8545   # trace 仍走 op-geth（finalized，trace 才有意义）
BLOCKSCOUT_INDEXER_WS=ws://op-geth:8546            # WS 仍走 op-geth
```

> trace 与 WS 故意保留 op-geth：trace 在 pre-confirmation block 上是 ill-defined（block 还没 finalized 就 trace 没意义）；Blockscout 的实时事件 push 用 WS，flashblocks-rpc 的 ws 现实现不全。

### 6.3 M2 实测必须验证的 4 个 reorg 指标

PR-2 验收时 chain-test2 上必跑：

| 指标 | 目标 | 测量方法 |
|---|---|---|
| 5 分钟 reorg 次数 | < 3 次 | grep `non_canonical` Blockscout backend log |
| reorg 平均深度 | ≤ 1 block | `SELECT MAX(reorg_depth) FROM blocks WHERE consensus = false` |
| frontend tx 闪烁率 | < 0.1% | Selenium / Playwright 重复 100 次 view-tx，统计消失次数 |
| stats 微服务 daily count 误差 | < 1% | 跟 op-geth 直查比对 |

### 6.4 M2 出问题的回退预案（10 分钟之内能切回稳定状态）

如果上面任意指标超标，按这个 fallback 操作：

```bash
# 1. 改 .env.flashblocks 把 indexer RPC 切回 op-geth
sed -i 's|BLOCKSCOUT_INDEXER_RPC=http://flashblocks-rpc:8545|BLOCKSCOUT_INDEXER_RPC=http://op-geth:8545|' dev/.env.flashblocks

# 2. 重启 Blockscout backend（保留 DB，indexer 会从最新 finalized block 续拉）
make blockscout-down && make blockscout-up

# 3. dApp 业务前端继续接 flashblocks-rpc:9548（这条不变），保住"快"体验
```

回退是 **5 分钟之内** 能完成的可逆变更，不丢数据，不掉链。所以 D3=force_d3b 风险可控。

### 6.5 不在 §6 范围内的 D3 演化路径

- M3 阶段如果 reorg 平均深度 > 1，会评估"双 indexer"架构（一个 finalized 一个 pre-confirm，frontend 选择性显示）。但目前判断 OP Stack flashblocks 在 1s block_time 下 reorg 极少（生产报告 < 0.01%）。

---

## 7. 故障 / 回滚场景

| 故障 | 影响 | 自动行为 | 人工介入 |
|---|---|---|---|
| op-rbuilder 挂 | bundle-proxy 收 5xx | bundle-proxy fallback 到 op-geth eth_sendRawTransaction，回到 v6 baseline 180 TPS | 30s 内告警，重启 rbuilder |
| rollup-boost 挂 | op-node engine 没人接 | op-node 进入 idle，链停止出块（critical）| 立即手动重启或回退 op-node `--l2` 直指 op-geth:8551 |
| flashblocks-rpc 挂 | 业务前端读不到 pre-confirm | dApp 自己回退到 op-geth :9545 | 重启 |
| bundle-proxy 挂 | dApp 写不进去 | docker restart unless-stopped 自动起 | 实测重启时间 < 2s |
| op-geth 挂 | 整个 stack 都挂 | rollup-boost 探测 op-geth down 后只走 op-rbuilder（degraded）| 立即重启 op-geth；如果 rbuilder 持续输出，op-geth 重启后从 rbuilder 同步追平 |
| Blockscout 挂 | 浏览器看不到，不影响链 | docker restart unless-stopped | — |

**回滚到 v6**: 在 chain-test2 上简单一行 `make flashblocks-down && make blockscout-down && make dev-down && git checkout main && make dev-up`，~3 分钟回到 v6 dev 环境。

---

## 8. 实施清单（PR 切分）

> 一次性大 PR 不可 review，按 milestone 分 3 个 PR。

### 8.1 PR-1（M1）：bundle-proxy 模块 + 设计 doc 集

**范围**:
- 本 doc（`docs/PHASE2_INTEGRATION.md`）
- `dev/bundle-proxy/` 完整模块（fastify + undici + 单元测试 + Dockerfile）
- `dev/bundle-proxy/mock-rbuilder/`（mock 服务，本地 unit 测试）
- 不改 `docker-compose.yml`，不改 Makefile

**验收**:
- bundle-proxy 单元测试 100% 通过
- 本地 `node spammer.js` → bundle-proxy → mock-rbuilder 全链路日志
- 0 RPC error，0 hang

### 8.2 PR-2（M2）：v7 stack 联调 + Makefile target

**范围**:
- `dev/docker-compose.flashblocks.yml`
- `dev/.env.flashblocks`
- `dev/Makefile` 新 target（flashblocks-up 等）
- `dev/blockscout/envs/backend.env.tpl` 参数化（默认仍指 op-geth）
- `dev/scripts/flashblocks-up.sh`（如果需要 health check 包装）

**验收**:
- chain-test2 上 `make dev-up-flashblocks` 一键起完整 v7 stack
- `make verify-cgt` 全套 10 用例通过（业务合约层兼容）
- `make test-deploy` Faucet drip 通过
- `tokenspammer` 走 bundle-proxy:9560 跑 200/500/800 TPS 三档，inclusion ≥ 95%

### 8.3 PR-3（M3）：长跑 + 故障注入

**范围**:
- `dev/scripts/stress-soak-flashblocks.sh`（24h 长跑）
- `dev/scripts/chaos-{rbuilder-down,proxy-down,...}.sh`（故障注入）
- `docs/STRESS_TEST_REPORT_V7.md`（结果）

**验收**:
- 24h soak 在 500 TPS 0 incident
- 故障场景实测 fallback 行为符合 §7 表格
- 业务方 sign-off

---

## 9. 不在本 Phase 范围（明确划定）

- ❌ Sepolia / mainnet L1（D1=A，dev 不上 Sepolia）
- ❌ op-rbuilder 多实例水平扩展（路径 4，需要 1500+ TPS 才考虑）
- ❌ op-reth 替换（路径 5-6，5000+ TPS 才考虑）
- ❌ bundle-proxy 部署 bproxy（builder-playground 限定，mychain 用不上，详见 `HIGH_TPS_RESEARCH.md` §13）
- ✅ Blockscout indexer 切到 flashblocks-rpc（D3=force_d3b，M2 阶段实施 + reorg 监控；详见 §6）
- ❌ v6 retire（要 v7 稳定 7+ 天后再决定）

---

## 10. 关键参考

| 资料 | 路径 | 用途 |
|---|---|---|
| Phase 1 完整研究 | `docs/HIGH_TPS_RESEARCH.md` | 800 TPS 上限依据、bproxy 不要 |
| bundle-proxy 模块设计 | `docs/PHASE2_BUNDLE_PROXY.md` | M1 实现细节 |
| v6 压测报告 | `docs/STRESS_TEST_REPORT.md` | 180 TPS baseline 与回退目标 |
| OP Stack flashblocks 文档 | https://docs.optimism.io/operators/sequencer/flashblocks | 上游协议规范 |
| op-rbuilder repo | https://github.com/flashbots/op-rbuilder | image 选型 |
| rollup-boost repo | https://github.com/flashbots/rollup-boost | engine API dispatcher |

---

## 附录 A：变更影响最小化的设计取舍

| 选择 | 备选 | 我们选哪个 | 为什么 |
|---|---|---|---|
| docker-compose.flashblocks.yml 作为 override | 单独写一份 docker-compose.v7.yml | override | 复用 anvil/op-geth/op-node/op-batcher 定义，diff 最小 |
| op-node `--l2` 改指 rollup-boost | 用环境变量切换 | docker-compose 直接覆盖 command | 不让 main `.env.example` 被 v7 污染 |
| chainId 改成 175700 | 复用 42170 | 改 | 业务方指定，且 chainlist 未注册 |
| dev/.env.flashblocks 与 dev/.env 共存 | 单 .env 加变量 | 共存 | `make flashblocks-*` 自动 source 这个文件，不影响 v6 |
| bundle-proxy 用 Node.js (fastify) | Rust / Go | Node.js | 见 PHASE2_BUNDLE_PROXY.md §4，1-2 天能写完 |
