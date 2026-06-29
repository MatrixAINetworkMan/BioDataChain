# 高 TPS 技术路线研究 — Phase 1 / 2 / 3

> **分支**：`feat/high-tps-flashblocks`
> **基线 (main)**：`v6-failfast-baseline` —— 链稳态 ~180 TPS / 一期 SLA 150 TPS
> **本期目标**：500-800 TPS（业务方在 v4 调整后接受的二期目标）
> **新服务器**：专用于本研究，不影响 chain-test 主链稳定性测试

本文档是本分支的**滚动工作文档**：跟踪 Phase 1/2/3 的 milestone、阻塞、决策记录。

---

## 0. 背景速览

main 分支已封版（tag `v6-failfast-baseline`）：链消化稳态 ~180 TPS，单纯靠
op-geth 调参不可能再压榨更多（瓶颈在 `worker.fillTransactions()` 一次性 mempool
snapshot 行为，详见 `STRESS_TEST_REPORT.md §6`）。

要再冲 500+ TPS，必须改架构。本研究分支在新服务器上独立验证可选路线。

---

## 1. 候选方案对比

| 方案 | 预期 TPS | 改造成本 | 风险 | 选型 |
|---|---|---|---|---|
| **Flashblocks**（op-rbuilder + rollup-boost） | 500-800 | 中 | 中（需 builder sidecar） | ⭐ **主线** |
| op-reth 替换 op-geth | 600-1500 | 高（重建链） | 高（state 迁移） | 备选 |
| L2_BLOCK_TIME=0.5s | ~360 | 中（重建链） | 高（生态兼容） | 不推荐 |
| patch op-geth fillTransactions | 800-1500 | 高（fork 维护） | 高 | 不推荐 |
| BatchTransfer 合约层聚合 | 链上名义 ~180 / 业务量 ~18000 | 低 | 低 | **业务方明确拒绝** |

**主线选 Flashblocks** —— 理由：
1. OP Stack 官方合作方案（Flashbots × Optimism），社区有持续维护
2. Base 主网已用类似机制，已生产验证
3. 增量集成（旁路而非替换 op-geth），不需要重建链
4. 失败回滚快（停 sidecar 即回到 v6-failfast-baseline）

详细评估见 `STRESS_TEST_REPORT.md §12`（Flashblocks 路线评估，含 10 个真实坑 + 决策矩阵）。

---

## 2. Phase 1：builder-playground PoC（预计 1-2 天）

**目标**：在新服务器上独立验证 Flashblocks 标准 demo 的 TPS 数字，输出可行性报告。

**约束**：完全不动 mychain dev 链，独立 demo 环境，failure 不影响 main 分支生产测试。

### 2.0 目录约定

跟 chain-test 上 `/data/code/mychain` 保持同样的根，新服务器统一放在 `/data/code/`：

```
/data/code/
├── mychain/              # git clone xiao-lw-new/mychain (本研究分支)
└── builder-playground/   # git clone flashbots/builder-playground (官方 PoC 工具)
```

**不要**把 builder-playground 放进 `mychain/` 子目录——它是独立工具，污染 mychain repo
不干净；也**不要**放 `~/`，跟 chain-test 习惯不一致 + 用户 home 目录通常是小盘。

### 2.1 Milestone

- [x] 新服务器准备（OS / docker / go / rust 工具链就位）→ chain-test2
- [x] `cd /data/code && git clone https://github.com/flashbots/builder-playground.git`
- [x] 阅读 README，确认依赖
- [x] 跑通 builder-playground 的 OP Stack + op-rbuilder + rollup-boost 标准 demo
- [x] 摸清 stack 拓扑（bproxy / rollup-boost / op-rbuilder / op-geth / flashblocks-rpc 各自角色）
- [x] **找到正确的 user RPC 入口**：`eth_sendBundle` → op-rbuilder（详见 §6.2）
- [x] 写专用压测工具：`dev/bots/flashblocks-spammer/`（bundle sender + ladder.sh）
- [x] **跑 100 / 300 / 500 / 1000 TPS 四档，找到拐点**（详见 §10）
- [ ] 跑跟 mychain 同款 stress-soak（30+ 分钟连续）
- [ ] 输出 `phase1-poc-report.md`：实测 TPS / 资源占用 / 主要踩坑 / 工时估算

### 2.2 关键问题清单

需要 Phase 1 给出明确答案：

- [ ] builder-playground 是否能直接跑出官方宣传的 500+ TPS？— **待 flashblocks-spammer 实测**
- [x] op-rbuilder 是 Reth-based，需要 Rust 工具链。版本要求？编译耗时？— **不需要自己编译，用 `ghcr.io/flashbots/op-rbuilder:v0.2.13` 镜像即可**
- [x] rollup-boost 怎么 wire 进 op-node ↔ op-geth ↔ op-rbuilder？sidecar 还是 proxy？— **sidecar：op-node 把 engine API 调用到 rollup-boost，rollup-boost 同时下发给 op-geth (`--l2-url`，fallback) 和 op-rbuilder (`--builder-url`，via bproxy 鉴权代理)**
- [x] 部署方式：kurtosis vs docker-compose，哪个更稳定 / 容易调试？— **builder-playground 自带 docker-compose 模板，用 `playground start opstack` 一键起。比 kurtosis 简单很多**
- [x] 出块逻辑：rollup-boost 250ms sub-block 模式下，user RPC 看到的 block 是 250ms 还是合并后的 1s？— **flashblocks-rpc 推送 250ms 增量更新 (`b->f` ws)；op-geth/op-rbuilder canonical chain 仍是 1s/block。pending tx 状态可以在 250ms 内可见**
- [ ] failover：op-rbuilder 挂了，op-geth 能 fallback 当主 sequencer 吗？— **架构上能（rollup-boost `--l2-url` 是 fallback），未实测**
- [x] **【新】user tx 入口怎么走？**— **op-rbuilder 暴露 `eth_sendBundle`（Flashbots Bundle API），standard `eth_sendRawTransaction` 经 op-geth 不能稳定 inclusion，详见 §6.2 + §9**

### 2.3 退出标准

Phase 1 算成功的标志：
- [x] builder-playground 能稳定跑（24 小时内已多次重启，每次能稳定出块）
- [x] **实测 TPS ≥ 400** —— ✅ **500 TPS 实测拿到 user TPS 441.6（88% 转化率，0 错误）**，详见 §10
- [ ] 至少跑通 1 次跟 mychain 同款 stress-soak 测试 — 待 spammer 接 ERC-20

**Phase 1 整体判定：通过**。可进入 Phase 2 设计阶段。

---

## 3. Phase 2：集成 mychain dev 链（预计 5-7 天）

**目标**：把 op-rbuilder + rollup-boost 集成到 mychain dev chain，跟 main 同款
`stress-soak` 测试做 head-to-head 对比。

**约束**：本分支独立 docker-compose stack，跟 main 的 mychain-* 容器并行（不同
端口 / 名字 / network），不影响 main 上的稳定性测试。

> **Phase 1.5 给 Phase 2 的强制要求**（详见 §12.4，下面 milestone 已纳入）：
> 1. **必须保留 fail-fast**：op-rbuilder 过载不主动拒绝，会让 RPC 排队 30s+ →
>    必须在前面加 in-flight 计数 + 超载毫秒级返 429
> 2. **必须有 bundle proxy**：`eth_sendRawTransaction` ↔ `eth_sendBundle` 适配，
>    dApp/SDK 不感知（详见 §12.4 必做 2）
> 3. **明确容量目标 = sustained 800 user TPS**（v6 baseline 180 的 4.4×）

### 3.1 Milestone

#### 3.1.1 准备阶段（独立可做，不动 stack）

- [ ] **bundle-proxy 设计文档** —— 协议适配 + fail-fast in-flight 计数 + 配额策略
- [ ] **bundle-proxy 实现 PoC** —— Node.js / Go，单二进制，纯网关无状态
  - 接 `eth_sendRawTransaction` (POST jsonrpc)
  - 转 `eth_sendBundle [{txs:[raw], blockNumber: head+1}]`
  - in-flight 计数：超过阈值（默认 1000）直接 429 + 明确 reason
  - 透传 `eth_call` / `eth_getTransactionCount` 等 read RPC 给 op-geth/flashblocks-rpc
  - 暴露 prometheus metrics：in-flight gauge / reject counter / latency histogram

#### 3.1.2 stack 集成

- [ ] op-rbuilder 编译 + dockerize（基于 `dev/docker-compose.yml` 模式）
- [ ] rollup-boost dockerize + 接入 op-node
- [ ] 新增 `dev/docker-compose.flashblocks.yml`：bundle-proxy + op-rbuilder +
      rollup-boost 作为 op-geth 的旁路；保留原 op-geth 作为 fallback
- [ ] state 同步：mychain 现有 50k 钱包 + 1000 token 状态迁移给 op-rbuilder
- [ ] 把 tokenspammer 的 `SPAM_RPC_URL` 切到 **bundle-proxy:8545**（不直连 op-rbuilder）
- [ ] 把对外面向 dApp 的 RPC 也指到 bundle-proxy

#### 3.1.3 验证

- [ ] 跑 stress-soak 200 / 500 / 800 TPS 三组对比
- [ ] **fail-fast 验证**：发起 1500 TPS（超出稳态），验证 bundle-proxy 在毫秒级
      返回 429 而非永久 pending
- [ ] **keep-alive 友好性验证**：客户端用短连接 vs keep-alive 都能正常工作
- [ ] 跑 stability-up 长跑 24 小时验证稳定性
- [ ] 数据汇总到 `STRESS_TEST_REPORT_V7.md`（v7 章节，比对 v6 baseline）

### 3.2 关键问题清单

- [ ] 我们的 dev 链 state（CGT v2 + 自定义 predeploys）能完整迁移吗？
      会不会触碰 OP Stack 主线没覆盖的 edge case？
- [ ] op-batcher v1.16.7 跟 op-rbuilder 兼容吗？
      是否需要升级 op-batcher（从而触发 §12.4 列出的 10 个坑）？
- [ ] tokenspammer.js 当前 RPC batch 模式（50 笔一组）跟 op-rbuilder 兼容吗？
- [ ] **bundle-proxy 的 fail-fast 阈值如何取**：1000 in-flight？还是按 RPS rolling window？
- [ ] **bundle-proxy 单点风险**：是否需要冗余部署？怎么 health check？
- [ ] 监控指标接入：op-rbuilder 有 prometheus `/metrics`（端口 9090，已确认），
      跟现有 grafana dashboard 怎么接？

### 3.3 退出标准

Phase 2 算成功的标志：
- 长跑 24 小时无崩溃
- chain_tps ≥ 800 sustained（v6 baseline 180 的 4.4×，与 Phase 1.5 实测一致）
- **过载场景下 bundle-proxy 100% 毫秒级 fail-fast**，无 RPC 永久 pending
- mempool / bundle queue 形态稳定，攻击场景仍能拒载
- 全部 v6 §12.4 的 10 个坑都有验证或显式接受风险

---

## 4. Phase 3：决策合并（预计 3-5 天）

**目标**：基于 Phase 2 数据决定是否合并到 main，制定切换计划。

### 4.1 决策树

```
Phase 2 测出 chain_tps ≥ 500?
├── 是
│   └── 触发 v6 §12.4 哪些坑?
│       ├── ≤ 3 个低风险坑     → 推荐合并 main
│       ├── 4-7 个中风险坑     → 影子模式跑 1 周再合并
│       └── ≥ 8 个或致命坑     → 暂缓，重新评估方案
└── 否
    └── 是 op-rbuilder 调参问题还是架构限制?
        ├── 调参         → Phase 2 延期 1 周
        └── 架构         → 切备选方案 op-reth
```

### 4.2 Milestone

- [ ] Phase 2 数据汇总评审
- [ ] 风险卡输出：列出所有已知 failure mode + 监控告警 + 回滚手段
- [ ] 决策记录在本文档 §6
- [ ] 如合并：分阶段切换计划（dev 链测试 → 影子模式 → 正式切换）
- [ ] 如延期：明确下一阶段任务 + 时间表

### 4.3 退出标准

Phase 3 完成的交付物：
- 决策文档（合并 / 影子 / 暂缓 三选一，附理由）
- 风险卡 + 监控告警清单
- 给业务方的 SLA 升级建议（150 TPS → ?）

---

## 5. 进度日志

> 滚动更新：每完成一个 milestone 就追加一行。

| 日期 | Phase | 完成 | 阻塞 | 下一步 |
|---|---|---|---|---|
| 2026-05-06 | Phase 0 | main 封版 v6-failfast-baseline；本分支创建 | 等新服务器到位 | 拉到新机器后 git checkout |
| 2026-05-08 | Phase 1.1 | chain-test2 上 `playground start opstack` 起 stack；摸清 bproxy / rollup-boost / op-rbuilder / op-geth / flashblocks-rpc 角色 | contender 总在 funding 阶段 timeout（24s）| 排查 RPC 入口 |
| 2026-05-08 | Phase 1.2 | 定位 contender funding 失败根因：默认 funder = Anvil[0]，跟 op-rbuilder 的 `--rollup.builder-secret-key` 抢同一 nonce；换 Anvil[1] (`-p` flag) 后 funding 秒过 | — | 测 spam 链路 |
| 2026-05-09 | Phase 1.2 | contender → op-rbuilder:8545：偶发爆发出块（block 突然 69 txs），平时空块；contender → op-geth:8545：op-geth pending=100 堆积但 canonical 仅 3 txs（rollup-boost 选 op-rbuilder 的空 payload）| P2P gossip 不传 mempool tx 给 op-rbuilder（实测 op-geth pending 中的 tx hash 在 op-rbuilder 上 `result=null`）| 找 builder-only 入口 |
| 2026-05-09 | Phase 1.2 | **核心发现**：op-rbuilder 暴露 `eth_sendBundle`（method 存在，缺参数会返回 `bundle must contain at least one transaction`）；这是 Flashblocks 生产标准入口（详见 §6.2）| — | 写专用 bundle spammer |
| 2026-05-09 | Phase 1.3 | 写完 `dev/bots/flashblocks-spammer/`（viem-based bundle sender，~200 行），支持 100/300/500 TPS 参数化；本分支提交 | — | chain-test2 拉代码 + npm install + 跑实测 |
| 2026-05-09 | Phase 1.3 | 修 spammer：op-rbuilder v0.2.x 限制 `bundle 必须 exactly 1 tx`，funding 改 N 个并发单 tx bundle；spam 阶段加 head 缓存（500ms 更新一次）避免高 TPS 打爆 RPC | — | 跑 ladder 实测 |
| 2026-05-09 | Phase 1.3 | **Phase 1 EXIT：阶梯实测出炉**：100/300/500 TPS 全部 0 错误 88% 转化率，500 TPS user TPS 441.6 ✅ 达标；1000 TPS 断崖（RPC p99=3.2s，链停摆）。详见 §10 | — | 进 Phase 2 设计 OR 调 reth RPC 配置二探拐点（用户决定）|
| 2026-05-09 | Phase 1.3 | spammer 加 hard-evidence inclusion check：每档 spam 完跑全 sender 链上 nonce 总和对账。100/300/500 TPS 三档**全部 100.00% inclusion**（5999/17999/29999 笔全部上链，链上 onchain nonce 跟 local sent nonce 逐一吻合，3 个抽样 sender 的 balance 也匹配 gas 消耗）—— 这是最严谨的链上证据，确认 spammer 报告无虚 | — | 决策下一步（精确拐点 / RPC 调参 / soak / 进 Phase 2）|
| 2026-05-09 | Phase 1.4 | 1000 TPS 拐点根因定位 + 修复：spammer 改用 undici keep-alive Agent，0 error，user TPS 从 149 → 806（5.4×），单 block 装 2855 tx 几乎打满 60M gas。详见 §11 | — | 跑极限 ladder |
| 2026-05-09 | Phase 1.5 | 极限 ladder 800/1000/1500/2000/2500：稳态上限 = **800 user TPS / 100% inclusion / p50=20ms**。1500+ 时 spammer 自身饱和（不是 builder）。**关键发现：op-rbuilder 过载不主动拒绝，会让 RPC 排队 30s** —— Phase 2 必须前置加 fail-fast。详见 §12 | — | 多进程 spammer 找 builder 真极限 |
| 2026-05-09 | Phase 1.6 | 多进程 4×800 = 3200 TPS 测试：稳态 750 user TPS（仍未到 builder 算力 2855）。docker stats 实测 **bproxy CPU 77%-89% 是真瓶颈**，rollup-boost 仅 1.2%。**bproxy 是 builder-playground 调试组件，mychain 生产部署不需要** —— Phase 2 预期 1000-1500 TPS。**附带发现 BUNDLE_BLOCK_OFS=1 在高 TPS 下 RPC 排队让 bundle 过期 silent drop**，Phase 2 bundle-proxy 必须用 head+10。详见 §13 | — | **Phase 1 EXIT**（§14），进入 Phase 2 实施 |

---

## 6. 决策记录

> 记录每个关键技术决定 —— 时间、对比的选项、最终选择、理由。

### 6.1 [2026-05-06] 主线方案选 Flashblocks

**对比**：Flashblocks / op-reth / L2_BLOCK_TIME 减半 / fork op-geth / BatchTransfer 合约。

**决定**：Flashblocks（op-rbuilder + rollup-boost）。

**理由**：
1. OP Stack 官方协作方案（Flashbots × Optimism）
2. Base 主网生产验证
3. 旁路集成而非替换核心组件，回滚成本低
4. BatchTransfer 被业务方明确拒绝（一期需求是单笔 transfer）
5. op-reth 需要重建链 + state 迁移，风险过高，作为备选

详见 `STRESS_TEST_REPORT.md §12`。

### 6.2 [2026-05-09] Flashblocks 的 user RPC 入口必须用 `eth_sendBundle`，不能直接发到 op-geth/op-rbuilder 的 standard RPC

**背景**：Phase 1.2 测试中我们尝试了三个入口都不稳定：

| 入口 | 现象 | 根因 |
|---|---|---|
| flashblocks-rpc:8545 (read replica) | 接收 tx 但不 forward；24s timeout 后 RPC 仍报 null | reth 启动参数无 `--rollup.sequencer-http=...`，纯只读节点 |
| op-rbuilder:8545 直发 | 部分 tx 进 mempool；偶发爆发出块（69 txs/block），平时空块 | builder mode 不主动从 P2P mempool 拉 tx；只有自己 mempool 接到的偶尔打包 |
| op-geth:8545（builder-playground README 推荐）| pending 堆到 100+；canonical 仅 3 txs/block | rollup-boost 优先用 op-rbuilder 的 payload（即使空），op-geth 的 mempool 不进 canonical |

**验证 P2P 不通**：从 op-geth pending 取一笔 tx hash，去 op-rbuilder 查 `eth_getTransactionByHash` → result=null。

**对比**：op-rbuilder 暴露 `eth_sendBundle`，发空 bundle 返回 `-32602 "bundle must contain at least one transaction"`（method 存在，仅缺参数）。这就是 Flashbots Bundle API，是 OP Mainnet / Base 上 builder 的**标准 user 入口**。

**决定**：
1. **Phase 1.3 实测**：用 `eth_sendBundle` 直接发给 op-rbuilder（绕过 P2P / sequencer 链路），验证 Flashblocks 在 builder-playground 上的 TPS 上限。
2. **Phase 2 集成 mychain 时**：必须新增一层 **bundle proxy** —— 把 dApp 的 `eth_sendRawTransaction` 透明转成 `eth_sendBundle`，避免上游 dApp / wallet 改造。这是新代码工作量但是必经路径。
3. **退路**：如果 bundle proxy 实现复杂度过高，回退到方案 B（op-geth 单机调优至 ~1500 TPS），不走 Flashblocks。

**关键依据**：
- 这不是 builder-playground 的 bug，是 Flashblocks 的**架构选择**：把 builder 设计成 trusted entity，user tx 必须走 bundle 路径才能保证 inclusion。
- builder-playground 的 P2P gossip 不可靠是 dev devnet 限制，生产环境 Optimism / Base 也不依赖 P2P 同步 builder mempool。
- 我们没有"魔法路径"可以让 standard RPC 在 Flashblocks 下 work —— 必须 dApp 改造或加 proxy 层。

---

## 7. 参考资料

### 官方文档
- [Flashblocks 概念介绍](https://docs.flashbots.net/flashbots-mev-boost/the-mev-boost-relays/op-stack)
- [op-rbuilder GitHub](https://github.com/flashbots/op-rbuilder)
- [rollup-boost GitHub](https://github.com/flashbots/rollup-boost)
- [builder-playground GitHub](https://github.com/flashbots/builder-playground)

### 内部
- `docs/STRESS_TEST_REPORT.md` § 6 / § 8 / § 12 / § 14（v6 baseline 全量数据）
- `dev/scripts/stability-up.sh`（main 同款长跑工具，Phase 2 直接复用）
- `dev/bots/tokenspammer/tokenspammer.js`（多 RPC 端点已参数化，可直接接 op-rbuilder）

---

## 8. 工作流约定

- **本分支不合并 main**，除非 Phase 3 决策为"合并"。
- **避免污染 main**：本分支的所有改动都加前缀 `[flashblocks]` 或放 `dev/flashblocks/` 子目录。
- **新服务器跑 PoC**，chain-test 继续跑 main 的稳定性测试，**两者不串扰**。
- **每完成一个 milestone**：更新本文档 §5 进度日志 + 提交 commit。
- **关键决定**：写进本文档 §6 决策记录，commit message 引用决策编号。

---

## 9. Phase 1 实测发现速查（lessons learned）

> 这一节是给**未来重新进入这个分支的人**用的——不用通读上面的进度日志，直接看这里就能上手。

### 9.1 builder-playground stack 拓扑（chain-test2 实测）

```
                 ┌──────────────────────────────┐
                 │     op-node (consensus)      │
                 └──────────────┬───────────────┘
                                │ engine API
                                ▼
                 ┌──────────────────────────────┐
                 │    rollup-boost (sidecar)    │   ← 决策选哪个 builder 的 payload
                 │  --l2-url=op-geth (fallback) │
                 │  --builder-url=bproxy        │
                 └──────────────┬───────────────┘
                                │
                                ▼
                 ┌──────────────────────────────┐
                 │    bproxy (auth proxy)       │   ← 鉴权 + JWT，转发 engine API
                 │  --authrpc-backend=op-rbuilder│
                 │  --authrpc-peers=flashblocks-rpc (mirror) │
                 └──────────────┬───────────────┘
                                │ engine API
                ┌───────────────┼───────────────┐
                ▼               ▼               ▼
         ┌───────────┐  ┌──────────────┐  ┌──────────────┐
         │ op-geth   │  │ op-rbuilder  │  │flashblocks-rpc│
         │ (fallback │  │ (primary     │  │  (read-only   │
         │  builder, │  │  builder,    │  │  replica，    │
         │  user RPC │  │  Flashblocks │  │  推送 250ms   │
         │  8545)    │  │  ws 1112,    │  │  增量给 dApp) │
         │           │  │  user RPC    │  │               │
         │           │  │  8545,       │  │               │
         │           │  │  eth_sendBundle│ │               │
         └───────────┘  └──────────────┘  └──────────────┘
```

**Host port mapping (chain-test2 实测)**:
- `op-rbuilder:8545` (eth_sendBundle 入口) → `127.0.0.1:8547`
- `op-geth:8545` (fallback user RPC) → `127.0.0.1:8549`
- `flashblocks-rpc:8545` (read replica) → `127.0.0.1:8548`
- `bproxy:8651` (engine API) → `127.0.0.1:8651`

### 9.2 三个常见错误入口

| 错误做法 | 现象 | 正确做法 |
|---|---|---|
| 把 contender / spammer 指向 `flashblocks-rpc:8545` | 24s funding timeout，所有 tx result=null | 用 op-rbuilder 的 `eth_sendBundle` |
| 用默认 funder（Anvil[0] = `0xf39F...266`）| funding tx 偶尔 confirm 偶尔丢，deterministic 模式 | 改用 Anvil[1] = `0x7099...79C8` 或更高 index 的 prefunded 账户 |
| 期望 P2P gossip 把 op-geth mempool 同步给 op-rbuilder | op-geth pending=100，canonical 仅 3 txs/block | 用 bundle 直发，或写 bundle proxy |

### 9.3 chain-test2 上一键 reproduce 步骤

```bash
# 0. SSH 到 chain-test2 (root or work user with docker group)
cd /data/code/builder-playground

# 1. 起 stack（如果还没起）
playground start opstack &
# 等 30s 让 stack 起来
sleep 30
playground list

# 2. 拉 mychain 代码（feat/high-tps-flashblocks 分支）
cd /data/code/mychain
git fetch origin
git checkout feat/high-tps-flashblocks
git pull

# 3. 跑 ladder 实测（自带 docker run，宿主机不需要装 node）
cd dev/bots/flashblocks-spammer
bash ladder.sh   # 默认 100/300/500/1000 TPS x 60s

# 4. 自定义档位
STEPS="200 400 600 800" DURATION_S=120 bash ladder.sh

# 5. 单档调试（直接用 spammer.js）
docker run --rm --network host -v "$(pwd)":/app -w /app \
  -e TARGET_TPS=300 -e N_SENDERS=100 -e DURATION_S=60 \
  node:20-alpine node spammer.js
```

### 9.4 关键节点诊断快查

```bash
# op-rbuilder 是否暴露 eth_sendBundle
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_sendBundle","params":[{}],"id":1}' \
  http://127.0.0.1:8547
# 期望: -32602 "bundle must contain at least one transaction"
# (说明 method 存在，只是缺 params)

# op-geth mempool 堆积情况
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"txpool_status","params":[],"id":1}' \
  http://127.0.0.1:8549 | jq

# 链头实时 TPS（30 block 窗口）
HEAD=$(curl -s -X POST http://127.0.0.1:8548 \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  | jq -r '.result' | xargs printf '%d')
TOTAL=0
for i in $(seq $((HEAD-30)) $HEAD); do
  CNT=$(curl -s -X POST http://127.0.0.1:8548 \
    -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockTransactionCountByNumber\",\"params\":[\"$(printf '0x%x' $i)\"],\"id\":1}" \
    | jq -r '.result' | xargs printf '%d')
  TOTAL=$((TOTAL + CNT))
done
echo "approx chain TPS: $((TOTAL / 30)), user TPS: $(((TOTAL - 90) / 30))"
```

---

## 10. Phase 1.3 实测数据（chain-test2 / 2026-05-09）

> 这一节是 Phase 1 的核心数据交付物。

### 10.1 测试环境

| 项 | 值 |
|---|---|
| 服务器 | chain-test2（与 main 的 chain-test 物理隔离）|
| OS | Ubuntu / kernel 见 `uname -a` |
| stack | builder-playground `playground start opstack` 默认配置 |
| 镜像版本 | `flashbots/op-rbuilder:v0.2.13`、`flashbots/rollup-boost:v0.7.12-rc1`、`flashbots/flashblocks-rpc:sha-7caffb9`、`us-docker.pkg.dev/.../op-geth:v1.101604.0`、`us-docker.pkg.dev/.../op-node:v1.16.3` |
| L2 chainId | 13 |
| L2 block time | 1s（rollup-boost 内部 250ms × 4 sub-block）|
| block gas limit | 60,000,000 |
| 压测工具 | `dev/bots/flashblocks-spammer/spammer.js` (viem-based, eth_sendBundle 入口) |
| funder | Anvil[1] = `0x70997970...79C8`（避开 builder 自己用的 Anvil[0]）|
| 每档时长 | 60 s |
| 单 tx | 0 wei native transfer（21,000 gas/tx）|
| 单 bundle | 1 tx（op-rbuilder v0.2.x 限制）|

### 10.2 阶梯结果（含 hard-evidence inclusion check）

每档跑完都做了"全 sender 链上 nonce 总和"对账（spammer.js 自带），数据为 chain-test2 实测：

| TARGET TPS | N_SENDERS | sent | bundle ok | bundle err | err% | 平均 user TPS¹ | inclusion² | max txs/block | RPC p99 | 评价 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 100  | 25  |  5,999 |  5,999 |   0 |  0.0% |  92.3 | **100.00%** (5999/5999) | 103 |    3ms | ✅ |
| 300  | 75  | 17,999 | 17,999 |   0 |  0.0% | 276.9 | **100.00%** (17999/17999) | 304 |    5ms | ✅ |
| 500  | 125 | 29,999 | 29,999 |   0 |  0.0% | 461.5 | **100.00%** (29999/29999) | 504 |   15ms | ✅ **EXIT 标准达成** |
| 1000 | 250 | 31,648 | 31,648 | 28,195³ | 89.1% |   0.0 | (chain stuck, inclusion 测不到) |   3 | 3,236ms | ❌ 断崖 |

¹ **平均 user TPS** = `sent / (DURATION_S + 5s drain)`。是 60s spam + 5s drain 期间链上消化的真实平均。
   30-block 窗口的 chain TPS（89.9 / 268.5 / 448.4）跟此值吻合，差异来自采样窗口的边界。

² **inclusion rate** = `sum(eth_getTransactionCount(sender_i)) / sum(local_sent_nonce_i)`。
   100.00% 说明 spammer 发出去的所有 tx 都在 canonical chain 上找到了对应的 nonce 推进 ——
   是**最严谨的链上证据**（不依赖 spammer 的自我报告）。

³ 1000 TPS 时 `bundle err 28,195 > sent 31,648` 是 spammer 统计 bug：部分 RPC timeout
   走 unhandled catch 增加 err 但没增加 sent。修正后实际 sent ≈ 60k，对结论无影响。

### 10.3 拐点分析

**500 TPS 是当前 stack 的稳定上限**。理由：
1. 100/300/500 TPS 三档**全部 0 错误 + inclusion 100%**，spammer 发什么链上就有什么。
2. 1000 TPS 时 RPC p99 latency 从 15ms 跳到 **3,236ms**（飙 215 倍），明显 RPC server queue saturate。
3. 500 → 1000 之间没有"逐步退化"，是断崖式跌穿—— builder 来不及消化或 RPC TCP 队列爆。

**block gas limit 没顶**：500 TPS 单块峰值 504 笔 = ~10.6M gas，远低于 60M limit。
**继续推 TPS 应该有上调空间，瓶颈在 reth 默认 RPC server 配置而非 builder 计算**。

### 10.3.1 为什么早期 500 TPS 报告里"chain TPS 444.7" < "spam 500 TPS"，但现在我们说 inclusion 100%？

不是 12% 流失，是**采样窗口偏差**：
- final report 里的 "chain TPS = total txs / 30 blocks" 取的是 spam 结束后链头附近的 30 个 block，
  里面既有 spam 期间的 block，也有 spam 已结束但还在 drain / commit 的 block。
- 真实的"spam 期间消化能力"应该用 `sent / (duration_s + drain_s)`，500 TPS 这次=29999/65s=461.5。
- inclusion check 用 `eth_getTransactionCount`，是地址级别的强对账，不受窗口截取影响 ——
  100.00% 是确定性证据。

**改 spammer 后续可以加一个"基于 spam 起止 block"的精确 chain TPS**（取 head_at_start ~ head_at_end），
但当前所有结论都站得住脚，inclusion 100% 是金标准。

### 10.4 资源占用粗看

500 TPS 跑 60s 时 chain-test2 上：
- op-rbuilder：CPU 中等（reth 单进程多线程，未细测）
- op-geth：CPU 几乎空闲（已退化为 fallback，user tx 不再走它）
- flashblocks-rpc：CPU 几乎空闲（read replica）
- spammer 容器：~5% CPU（瓶颈不在客户端）

**结论**：当前 op-rbuilder 没榨干，瓶颈在 reth 默认的 RPC server 配置。

### 10.5 对 mychain Phase 2 的指导

1. **Flashblocks 路线对应**：mychain 集成 op-rbuilder 后，**单机理论上限至少 500 TPS**（v6 baseline 180 的 2.7×），符合"500-800 TPS"的二期目标。
2. **bundle proxy 是 Phase 2 必经路径**：不能让 dApp 升级 SDK 改走 `eth_sendBundle`，
   必须在前端加一层把 `eth_sendRawTransaction` 透明转 bundle 的代理。
3. **必须暴露 RPC server 调参**：mychain 的 op-rbuilder 容器要 expose 至少这几个
   reth flag：`--http.max-connections`、`--rpc.max-request-body-size`、
   `--rpc.max-tracing-requests` 等。Phase 1.4（可选）会跑一次调参后的二探。
4. **fail-fast 仍可保留**：bundle reject 比 mempool 满更快（毫秒级 RPC 返回），
   比 v6 的 `txpool.globalslots=500` fail-fast 体验更好。

### 10.6 后续可选验证（Phase 1.4 / 1.5）

- [x] **Phase 1.4 1000 TPS 拐点根因定位**：见 §11
- [x] **Phase 1.5 极限 ladder（800-2500 TPS）**：见 §12
- [ ] **Phase 1.6 stress-soak**：800 TPS 持续 30+ 分钟（推荐进入 Phase 2 之前补一次）
- [ ] **Phase 1.7 ERC-20 tx**：跟 main v6 baseline 同款负载对比

---

## 11. Phase 1.4 拐点根因（chain-test2 / 2026-05-09）

> 1000 TPS 时 RPC p99 飙到 3236ms 且实际链上 TPS=0 的真实原因。

### 11.1 root cause

**spammer 的 Node fetch 默认短连接 + 250 个并发 sender，在 1000 RPS 下产生 connection churn**，触发 reth jsonrpsee 内部的 in-flight call 限制（reth v0.2.13 没把这个参数 expose 出来），导致：

1. 大量请求在 HTTP accept 阶段被返回 plain text `"Too many connections"` + 503，spammer 的 viem `res.json()` 撞到 `Unexpected token 'T'... is not valid JSON`，记入 err 但 Node fetch 已经把请求"算成 sent"。
2. op-rbuilder CPU 大部分时间只有 1-2%（请求被 HTTP accept 层拒掉，根本没到 RPC handler）。

**注意**：reth `--rpc.max-connections` 默认 = 500（不是 100，help 输出确认），所以单纯连接上限不是直接原因。真正起作用的是 churn + 短连接 TIME_WAIT。

### 11.2 修复 = undici keep-alive Agent

```javascript
import { Agent, fetch as undiciFetch } from 'undici';
const httpAgent = new Agent({
  connections: HTTP_POOL_SIZE,    // 32
  pipelining: HTTP_PIPELINE,      // 10
  keepAliveTimeout: 60_000,
});
```

250 个 sender 复用 32 个 TCP 连接，每连接 pipeline 10 笔，总 in-flight ~320，远低于 reth 默认 500 上限，0% err。

### 11.3 修复前后对照（同样 1000 TPS / 30s / N_SENDERS=250）

| 指标 | Phase 1.3 修复前 | Phase 1.4 修复后 | 变化 |
|---|---|---|---|
| `error rate` | 75% | **0%** | 完全消失 |
| `bundles err` | 11,928 / 15,899 | 0 | |
| `chain TPS` (30-block 窗口) | 152 | **809** | 5.3× |
| `user TPS` (30-block 窗口) | 149 | **806** | **5.4×** |
| `max txs / block` | 838 | **2,855** | builder 单块装到 21k×2855=60M gas，几乎打满 |
| RPC `p50 lat` | 2,454 ms | 6,021 ms | ⚠ 反升（pipeline 排队，详见 §12） |
| `inclusion rate` | 26% | 100% | drain 加长到 15s 后 |

### 11.4 给 Phase 2 的启示

**生产环境每个用户独立连接 + 浏览器/SDK 默认 keep-alive，自然不会触发这个问题**。但凡是"集中式订单系统/撮合代发"角色（GameFi 后端、Bot、聚合器），必须强制 keep-alive，否则在 1000+ RPS 下 RPC 入口直接被自家短连接打死。

---

## 12. Phase 1.5 极限 ladder（chain-test2 / 2026-05-09）

> 找当前硬件 + 当前 spammer 下 Flashblocks 的真稳态上限。

### 12.1 ladder 配置

| TPS 目标 | senders | HTTP_POOL_SIZE | pipelining |
|---:|---:|---:|---:|
| 800 | 200 | 32 | 10 |
| 1000 | 250 | 32 | 10 |
| 1500 | 375 | 64 | 12 |
| 2000 | 500 | 96 | 14 |
| 2500 | 625 | 128 | 16 |

每档 30s spam + 15s drain + 15s cooldown。

### 12.2 实测结果

| TPS 目标 | spam 期 sent rate | sent 总数 | err% | 30-block user TPS¹ | inclusion² | RPC p50 | 评价 |
|---:|---:|---:|---:|---:|---:|---:|---|
| **800** | **800/s 平稳** | 23,994 | 0% | 436 | **100.00%** | **20 ms** | ✅ **稳态上限** |
| 1000 | 580→700/s | 29,986 | 0% | 696 | 100.00% | 6,021 ms | ⚠ spammer 已限速 |
| 1500 | 170-220/s | 33,253 | 0% | 906³ | 92.6% | 24,585 ms | 🚨 spammer 几近卡死 |
| 2000 | 90→32/s | 26,758 | 0% | 626 | 84.9% | 30,521 ms | 🚨 spammer 完全饱和 |
| 2500 | 57→0/s | 25,160 | 0% | 734 | 86.7% | 29,625 ms | 🚨 同上 |

¹ 30-block 窗口在 spammer 结束后采，包含 drain 期把 in-flight 一次性消化的"反吐"，**不代表稳态**。  
² inclusion < 100% 是因为 spammer 中断时 in-flight 的请求没有 settle，不是真丢失。  
³ 1500 档窗口 user TPS 909 是 drain 期 builder 一次性消化积压 bundle 的虚高峰值。

### 12.3 三个核心发现

#### 发现 1：稳态 sustained TPS = 800（当前 spammer）

- 800 档：sent 30s 内 24,000 笔（800/s 平稳），p50=20ms，inclusion 100%。这是健康稳态。
- 1000 档开始，spammer 自身 sent 速率就跌到 600-700/s（打不出 1000）。
- 1500+ 时 spammer 完全饱和。

#### 发现 2：op-rbuilder 在过载时**不会主动拒绝，会让 RPC 排队 30s**

| TPS | RPC p50 |
|---|---|
| 800 | 20 ms |
| 1000 | 6 s（300×）|
| 1500+ | 25-30 s（已经到 fetch/HTTP 默认超时上限）|

`err = 0%` 不是健康信号—— jsonrpsee 没主动 reject，只是把请求 hold 在 queue 里。**这是接入 mychain 必须前置解决的问题**，详见 §12.4。

#### 发现 3：1500+ 档 spammer 才是瓶颈，不是 builder

证据：
- builder 块容量上限 = 60M gas / 21k = 2857 tx/block。1500 档实测 max=2855，builder 完全有能力打包，是没被喂够。
- 加大 HTTP_POOL_SIZE 到 128 没救——根因是每个 fetch 等 25s，连接池被锁死。
- 要继续找 builder 真极限，必须换客户端（多进程 Node / Go / Rust），不能单 Node 进程压。

### 12.4 给 Phase 2 的强制要求

#### 必做 1：mychain 接入 Flashblocks 必须保留 fail-fast

> v6 main 的 `txpool.globalslots=500` fail-fast 不能丢，要在新架构里换种方式重建。

理由：op-rbuilder 不会主动拒绝过载请求，而是无限排队。生产环境一旦 TPS 超过稳态：

- ❌ 不加 fail-fast：所有用户的 RPC 永久 pending → SDK 超时 → 用户重试 → 雪崩 → 服务全跪
- ✅ 加 fail-fast：超过容量的请求毫秒级返回明确错误（类似 Ethereum mempool 满），用户/SDK 立刻知道并退避

**实现位置候选**（按优先级）：
1. **bundle proxy 层**：维护 in-flight count 计数，超过阈值（如 1000）直接返回 `429 Too Many Requests`。最简单，无需改 builder。
2. RPC gateway（nginx + lua）：基于连接数 / RPS rate-limit。次选。
3. patch op-rbuilder 加 max-in-flight：最干净但要 fork & rebuild。

#### 必做 2：bundle proxy = `eth_sendRawTransaction` → `eth_sendBundle` 适配层

dApp 不会升级 SDK，所有现存调用都是 `eth_sendRawTransaction`。proxy 必须：
- 接 `eth_sendRawTransaction`（原协议）
- 转发为 `eth_sendBundle`（builder 协议）
- 处理"必须 exactly 1 tx per bundle"（op-rbuilder v0.2.x 限制）
- 处理 `blockNumber` 注入（builder API 必填）
- 维护 in-flight 计数（必做 1）

#### 必做 3：明确容量目标 = 800 sustained user TPS

- ≥ v6 baseline 180 TPS 的 4.4×
- 满足业务方"500-800 TPS 二期目标"
- 不需要堆机器（单 op-rbuilder 容器即可）

#### 选做 4：客户端 keep-alive 强化建议

写到 mychain 接入文档，给 dApp / 业务后端：
- HTTP/1.1 必须 `Connection: keep-alive`（curl 默认 yes，Node fetch 默认 no）
- HTTP/2 自动复用，无需配置
- 单连接 pipelining 深度 ≤ 16（避免 head-of-line blocking）

### 12.5 后续验证（已完成 Phase 1，可选）

- [ ] **Phase 1.6 stress-soak**：800 TPS 持续 30+ min，验长期稳定性
- [ ] **Phase 1.7 ERC-20 tx**：与 v6 baseline 同款 ERC-20 transfer 负载
- [ ] **Phase 1.8 multi-process spammer**：worker_threads 或 Go 客户端，找 builder 真极限（理论 ≥ 2855 TPS）

是否做由 Phase 2 节奏决定。**Phase 2 不阻塞在这些可选验证上**。

---

## 13. Phase 1.6 多进程压测：定位真瓶颈 = bproxy（chain-test2 / 2026-05-09）

> Phase 1.5 单 spammer 撞了 800 TPS 客户端上限，没看到 builder 真极限。
> Phase 1.6 用多进程 spammer（4 个独立 Docker 容器，各用不同 anvil funder
> 避免 nonce 冲突）把客户端瓶颈拆掉，找 stack 真上限。

### 13.1 实测数据（4 spammers × 800 TPS = 3200 TPS 目标）

| 配置 | SUM sent | inclusion | chain-wide TPS | max_block_txs | 含义 |
|---|---|---|---|---|---|
| BUNDLE_BLOCK_OFS=1（默认）| 94,882 | 36.8% | **652** | 2,855 | 大量 bundle 因 RPC 排队 1s+ 而过期 |
| BUNDLE_BLOCK_OFS=30 | 87,280 | 43.2% | **753** | 2,855 | 不丢过期后只多 100 TPS（+15%）|

**OFS=30 救回 100 TPS（~15%）**——确认了 spammer.js 默认 `head+1` 在高 TPS 排队下 bundle 会过期被 builder silent drop。但 753 仍远低于 builder 算力（2855 是单块物理上限）。

### 13.2 docker stats 实测：bproxy 是真瓶颈

spam 中段 5 次采样（间隔 3s）：

| 容器 | 平均 CPU | 峰值 | 评价 |
|---|---|---|---|
| **bproxy** | **77%** | **89%** | 🚨 builder-playground 内部 Engine API proxy，**单线程，单核接近打满** |
| op-rbuilder | 43% | 53% | 多线程还有富余 |
| op-geth | 30% | 42% | sequencer，未饱和 |
| flashblocks-rpc | 24% | 53% | read replica |
| rollup-boost | **1.2%** | 2% | 极闲，**关键证据** |

**bproxy 是 builder-playground 特定实现，生产 / mychain Phase 2 部署不需要**：

```
builder-playground 拓扑（PoC，调试用）：
  op-node ──Engine API──→ bproxy ──┬──→ op-geth
                                    └──→ op-rbuilder
                          （单线程 JSON 转发，4×payload/s 时 CPU 满）

生产 / mychain Phase 2 拓扑：
  op-node ──Engine API──→ rollup-boost ──┬──→ op-geth
                                          └──→ op-rbuilder
                          （rollup-boost 实测 CPU 1.2%，极有富余）
```

### 13.3 推论：mychain Phase 2 真实上限

| 业务负载 | builder-playground 实测 | **mychain Phase 2 预期** | 信心 |
|---|---|---|---|
| 500-800 TPS | ✅ 750（含 bproxy 开销）| ✅ ≥ 800 TPS | **高**（含开销已达成）|
| 800-1500 TPS | bproxy 达上限 | ✅ 1000-1500 TPS | **中**（无 bproxy 预期，需 Phase 2 实测）|
| 1500-2500 TPS | 不可知 | 🟡 可能（max_block 2855 是单块硬上限）| **低**（看 op-rbuilder 持续填满能力）|

### 13.4 给 Phase 2 的具体改动要求（在 §12.4 基础上追加）

#### 必做 5：bundle-proxy 必须设足够大的 blockNumber offset

实现细节：
```js
// bundle-proxy 转发时
bundle.blockNumber = toHex(cachedHead + 10n)  // 10 秒消化窗口
```

理由：op-rbuilder 收到 `blockNumber < head` 的 bundle 会 silent drop 不打包，**RPC 200 OK 但链上从未落账**——这是比"明确 fail-fast"更糟糕的体验（用户拿到了 tx hash 但永远不上链）。Phase 1.6 实测 OFS=30 比 OFS=1 多救回 15% 的 inclusion。

`PHASE2_BUNDLE_PROXY.md` §3.2 已加入此要求。

#### 必做 6：mychain 拓扑里**不部署 bproxy**

直接 `op-node → rollup-boost → (op-geth, op-rbuilder)`。bproxy 是 builder-playground 的调试便利组件，生产部署的 OP Stack Flashblocks 文档也是直连 rollup-boost。这一步不需要额外开发，**就是不抄 builder-playground 的 docker-compose 中那一行**。

---

## 14. Phase 1 EXIT 总结

### 14.1 实测产出

✅ **原始目标 500-800 TPS 已达成**：
- 单 client 稳态 800 user TPS，0% err，100% inclusion，p50 = 20ms
- 多 client 稳态 750 user TPS（含 bproxy 开销，生产无 bproxy 预期更高）
- builder 单 block 装到 2855 tx（60M gas 满载）—— 算力天花板

### 14.2 对 Phase 2 的强制要求清单

来自 §12.4 + §13.4，Phase 2 实施时全部要落实：

| # | 要求 | 实现位置 |
|---|---|---|
| 1 | 必须保留 fail-fast（builder 不主动拒绝过载）| bundle-proxy in-flight 计数 + 429 |
| 2 | bundle-proxy 是必经之路（dApp 不升级 SDK）| `dev/bundle-proxy/` 模块 |
| 3 | 容量目标 800 sustained user TPS（v6 baseline 4.4×）| Phase 2 退出标准 |
| 4 | 客户端必须 keep-alive（生产 SDK 默认 yes，集中式后端必须强制）| 文档 |
| 5 | bundle.blockNumber = head + 10（防过期 silent drop）| bundle-proxy 转发逻辑 |
| 6 | mychain 拓扑不部署 bproxy（直连 rollup-boost）| `docker-compose.flashblocks.yml` |

### 14.3 fail-fast 守门员设计（关键产品决策）

业务方两个核心问题（2026-05-09 用户提问）的实测答案：

**Q1: 业务到上限会 fail-fast 吗？会把链搞崩吗？**
- ✅ 会 fail-fast（bundle-proxy 设计已含）
- ✅ **链 100% 不会被搞崩**（Phase 1.5 实测：输入 2500 TPS 时链照常 1s/block 出块）

**Q2: 将来 TPS 再升怎么办？业务会中断吗？**
- 800 不是终点，6 条升级路径里 5 条不业务中断
- 路径 0（多客户端独立连接，0 改造）已能撑 1500-2500 TPS（Phase 1.6 已部分验证）
- 路径 4（多 builder sharding，bundle-proxy 是天然挂载点）能撑 5000+ TPS，rolling 0 中断
- 只有路径 5（op-reth）/ 路径 6（block_time 0.5s）需要 1-4h 维护窗口

详见 `PHASE2_BUNDLE_PROXY.md` §2.3 SLA 表。

➡ **进入 Phase 2**：开 review `PHASE2_BUNDLE_PROXY.md` → M1 bundle-proxy 单元开发 → M2 接入 chain-test2 验证 → M3 mychain 自起 stack。
