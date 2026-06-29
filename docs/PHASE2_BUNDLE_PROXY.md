# Phase 2 设计：bundle-proxy + fail-fast

> **状态**：v7.0 已实施（入口层完成）；Flashblocks 真集成延期到 v7.1
> **关联**：`HIGH_TPS_RESEARCH.md` §3 Phase 2 milestone、§12.4 强制要求
> **产物**：`dev/bundle-proxy/` 模块 + `dev/docker-compose.flashblocks.yml`

---

## 0. ⚠️ 2026-05 实测更新（v7.0 实施阶段发现）

### 0.1 op-rbuilder 0.3.x（sha-e5e6711）行为跟 1.2 节描述相反

**§1.2 表格在 v0.3.x reth-builder fork 下不再成立**。实测：

| 入口 | `eth_sendRawTransaction` | `eth_sendBundle` / `mev_sendBundle` / `flashbots_sendBundle` |
|---|---|---|
| op-rbuilder :8545 (0.3.x) | ✅ 接受但**全部 reject** | ❌ `Method not found` |

**`http.api=eth,web3,net,debug`** 不含 `mev` / `flashbots` namespace，且 op-rbuilder 源码里也没注册 bundle RPC。同时：

```
op-rbuilder eth_blockNumber = 0x0    ← builder 不持有 canonical chain state
op-rbuilder CPU ~ 0.5%               ← 完全没在干活
rollup-boost 日志 "builder has no payload, skipping get_payload" ← 每个 block 都 skip
```

### 0.2 根因：op-rbuilder 是 stateless builder

reth-builder fork 的设计：
- 收 `engine_newPayload` / `engine_forkchoiceUpdated` 但**不 import canonical block**到本地 chain state
- 收 `eth_sendRawTransaction` 时无法做 nonce/余额验证 → 全部 reject
- 不暴露 bundle RPC → dApp 无路可投 tx 给 builder
- builder 的 tx 来源必须通过 op-node 的 sequencer attributes 或 p2p mempool gossip——dev 单节点环境两者都不通

### 0.3 v7.0 暂行方案：bundle-proxy 退化为「统一入口层」

```
dApp ──eth_sendRawTransaction──► bundle-proxy ───► op-geth (sequencer)
                                  │
                                  └─ 保留：fail-fast 限流 / 熔断 / metrics / chainId 拦截
                                  └─ 跳过：包装成 sendBundle、forward 给 op-rbuilder
```

操作：`export BUNDLE_PROXY_RBUILDER_URL=http://op-geth:8545` 后重启 bundle-proxy。
op-rbuilder / rollup-boost 容器保留（基础设施就位），但流量旁路。

**TPS 上限：跟 v6 op-geth 单链一致**（实测 600-700 稳态）。Flashblocks 不参与。

### 0.4 v7.1 TODO：op-rbuilder 真集成调研

- [ ] 读 https://github.com/flashbots/op-rbuilder README + `crates/op-rbuilder/src/payload_builder*.rs`
- [ ] 确认 dev 单节点环境 builder 怎么拿到 tx：
   - 选项 A：op-rbuilder 跑 sync node 模式（开 `--rollup.sequencer-http` 同步 mempool）
   - 选项 B：让 op-node 把 sequencer mempool 通过 builder API 喂 builder
   - 选项 C：base-mainnet flashblocks 部署里 builder/sequencer 关系是怎样
- [ ] 复制 base 的 op-rbuilder yaml 调参，重测 builder 是否产生 payload
- [ ] 如 builder 路径完全打通，再恢复 bundle-proxy 的 `BUNDLE_PROXY_RBUILDER_URL=http://op-rbuilder:8545` 默认

---

## 1. 为什么必须有 bundle-proxy

### 1.1 dApp 不会升级 SDK

主流 SDK（ethers.js / web3.js / viem / wagmi）调用都是 `eth_sendRawTransaction`。
让所有 dApp 升级到 `eth_sendBundle` 是不可能的（Flashbots Bundle API 是 mev 圈
小众扩展，主流 SDK 不内置）。

### 1.2 op-rbuilder 不接受 `eth_sendRawTransaction`（实测）

Phase 1.2 实测发现：

| 入口 | 接受 `eth_sendRawTransaction`？ | 接受 `eth_sendBundle`？ |
|---|---|---|
| op-geth :8545 | ✅ | ❌ |
| op-rbuilder :8545 | ❌（接受但不打包，因为不是 builder block-flow 的入口）| ✅ |
| flashblocks-rpc :8545 | ❌ read-only replica | ❌ |
| rollup-boost :8545 | ❌ Engine API only | ❌ |

**Flashblocks 架构里 user 交易必须走 `eth_sendBundle` → op-rbuilder**。所以
mychain 集成时必须有一层适配，把 dApp 发的 raw tx 包装成 bundle。

### 1.3 op-rbuilder 过载不主动拒绝（Phase 1.5 实测）

| TPS | RPC p50 | error rate |
|---|---|---|
| 800 | 20 ms | 0% |
| 1500 | 24,585 ms | 0% |
| 2000 | 30,521 ms | 0% |

p50 飙到 30s 但 err = 0%。这是 jsonrpsee 把请求 hold 在 queue 里的行为，不是
健康信号。生产环境会演变成：

```
入流量 1500 TPS（>稳态 800） →
  RPC queue 堆积 → p99 达 30s →
    SDK 默认 timeout（10-30s）触发 → 用户重试 →
      RPC queue 进一步爆 → 雪崩
```

**必须在 RPC 入口提前 fail-fast**：超过容量阈值时毫秒级返回明确错误，让客户端立刻
知道而不是 hang 30 秒。这跟 v6 main 的 `txpool.globalslots=500` fail-fast 是同
一个设计哲学，只是实现位置从 op-geth mempool 移到 bundle-proxy 入口。

### 1.4 容量 SLA 矩阵（业务方决策依据）

> 数字依据：Phase 1.5 单 client 实测 **800 TPS** + Phase 1.6 多 client 实测
> **750 TPS（含 builder-playground 的 bproxy 77% 开销，生产无 bproxy 预期更高）**。

| 业务负载 | 实测/预期 | 升级到这个能力需要什么 | 业务中断 |
|---|---|---|---|
| **≤ 800 TPS sustained** | ✅ 实测达成（Phase 1.5/1.6）| 直接 Phase 2 上线即可 | — |
| 800-1500 TPS | ✅ 高信心 | 路径 0：多客户端独立连接（生产环境天然如此）| 0 |
| 1500-2500 TPS | 🟡 中信心（max_block 2855 物理上限）| 路径 1：多进程客户端压测验证（1-2 天）| 0 |
| 2500-5000 TPS | 🟡 需 R&D | 路径 2-3：op-rbuilder 调参 + 镜像升级 | 30s 重启 |
| 5000-10000 TPS | 🟡 需 R&D | 路径 4：多 builder 水平扩展（bundle-proxy sharding）| 0 rolling |
| > 10000 TPS | 🔴 重大架构变更 | 路径 5-6：op-reth 替换 / block_time 0.5s | 1-4h 维护窗口 |

#### 关键设计含义：bundle-proxy 是天然的水平扩展挂载点

bundle-proxy 在路径 4 中可以按 sender 地址 hash 把流量分片到多个 op-rbuilder 实
例，op-rbuilder 不需要任何改造。这意味着：**业务从 800 涨到 5000+ TPS 时不用重
做架构、不用业务中断，只是部署多一个 op-rbuilder 容器 + bundle-proxy 加几行配置**。

#### 业务方两个核心问题的实测答案

**Q1: 业务到上限会 fail-fast 吗？会把链搞崩吗？**
- ✅ 会 fail-fast（bundle-proxy 设计 §3.3 已含）
- ✅ **链 100% 不会被搞崩**（Phase 1.5 实测：输入 2500 TPS 时链照常 1s/block 出块）

**Q2: 将来 TPS 再升怎么办？业务会中断吗？**
- 800 不是终点，6 条升级路径里 5 条不业务中断
- 路径 0（多客户端连接）+ 路径 4（水平扩展）已能扛 5000+ TPS，0 中断
- 只有路径 5-6 需要短维护窗口，且路径 0-4 用尽前永远不需要走

---

## 2. 架构对照

### 2.1 现状（v6 baseline，main 分支）

```
[dApp / SDK]
    │ eth_sendRawTransaction
    ▼
[op-geth :8545]──── txpool fail-fast (globalslots=500)
    │ Engine API
    ▼
[op-node] → [op-batcher] → [L1 anvil]
```

链稳态 ~180 TPS，攻击场景 fail-fast 健康。

### 2.2 Phase 2 目标拓扑

```
[dApp / SDK]                                  ┌─── 透传 read RPC ───┐
    │ eth_sendRawTransaction                  │                     │
    ▼                                         │                     │
┌──────────────┐  eth_sendBundle              ▼                     ▼
│ bundle-proxy │ ────────────────► [op-rbuilder :8545]      [flashblocks-rpc]
│  :8545       │                       │                          (read replica)
│  fail-fast   │                       │ Engine API
│  in-flight   │                       ▼
└──────────────┘                  [rollup-boost]
    │ fallback (op-rbuilder down)      │ Engine API
    │                                  ▼
    └────────► [op-geth :8546]    [op-node] → [op-batcher] → [L1]
                  (备用)
```

关键点：
1. **bundle-proxy 是 dApp 的唯一 RPC 入口**（占用 8545 端口）
2. op-rbuilder 不直接对外（只接 bundle-proxy）
3. op-geth 降级为备用执行客户端 + read RPC fallback
4. flashblocks-rpc 提供低延迟 read（pre-confirmation 视图）
5. **不部署 builder-playground 的 `bproxy` 容器**（关键，Phase 1.6 实测发现）

#### ⚠️ 为什么不抄 builder-playground 的 bproxy

builder-playground 在 op-node 与两个 EL 之间放了一个名为 `bproxy` 的 Engine API 转
发组件，作用是让 op-node 把 newPayload / forkChoiceUpdated 同时分发给 op-geth
（sequencer）和 op-rbuilder（builder），方便对比观察。这是 PoC / 调试便利组件。

Phase 1.6 多进程压测实测（详见 `HIGH_TPS_RESEARCH.md` §13.2）：

| 容器 | 平均 CPU | 评价 |
|---|---|---|
| **bproxy** | **77%（峰值 89%）** | 🚨 单线程 JSON 转发，4 sub-flashblocks/s × 大 payload 时打满 |
| rollup-boost | 1.2% | 极闲，**说明真正的协调层 rollup-boost 完全没饱和** |
| op-rbuilder | 43% | 还有富余 |

**结论**：bproxy 是 builder-playground 的人为开销，**生产 / mychain Phase 2 直接
`op-node → rollup-boost → (op-geth, op-rbuilder)`，不需要 bproxy**。这一步的实施
意义：
- 抄 builder-playground 的 docker-compose 时，**就是不抄 bproxy 那一行**
- mychain 的 op-node command 里 `--l2.engine-rpc=http://rollup-boost:8551`，**不
  指向 bproxy**
- 预期 mychain Phase 2 sustained TPS ≥ 1000-1500（去掉 bproxy 的 77% 开销后）

---

## 3. bundle-proxy 协议规范

### 3.1 入站方法路由

| 客户端调用 | bundle-proxy 行为 | 上游 |
|---|---|---|
| `eth_sendRawTransaction` | 包装为 bundle 转发 | op-rbuilder `eth_sendBundle` |
| `eth_call`、`eth_estimateGas` | 透传 | flashblocks-rpc（pre-confirm 视图）|
| `eth_getBalance`、`eth_getTransactionCount`、`eth_getBlockByNumber` | 透传 | flashblocks-rpc |
| `eth_getTransactionReceipt`、`eth_getLogs` | 透传 | op-geth（finalized 视图）|
| `eth_blockNumber`、`eth_chainId`、`eth_gasPrice` | 缓存（500ms TTL）| flashblocks-rpc |
| `net_version`、`web3_clientVersion` | 静态返回 | — |
| 其他（`debug_*`、`trace_*` 等）| 透传 | op-geth |
| `eth_sendBundle`（高级用户）| 直接转发，不包装 | op-rbuilder |

### 3.2 `eth_sendRawTransaction` → `eth_sendBundle` 转换

```
入：
  POST /
  {"jsonrpc":"2.0","method":"eth_sendRawTransaction","params":["0x02f8..."],"id":1}

出（到 op-rbuilder）：
  POST /
  {
    "jsonrpc":"2.0",
    "method":"eth_sendBundle",
    "params":[{
      "txs": ["0x02f8..."],         // exactly 1 tx (op-rbuilder v0.2.x 限制)
      "blockNumber": "0xN+10"       // ⚠️ head 缓存 + 10，不能 +1（详见下方 ⚠️）
    }],
    "id":1
  }

返回客户端：
  {"jsonrpc":"2.0","result":"0x<txHash>","id":1}
  其中 txHash = keccak256(rawTx)，本地算，不等 builder 响应
```

**关键设计**：

- `result` 立即返回 `tx hash`（链上识别符），跟标准 `eth_sendRawTransaction` 行为
  一致。客户端通过 `eth_getTransactionReceipt` 轮询确认。
- 不等 builder 响应：bundle-proxy 把 builder 调用做成 fire-and-forget（带超时和
  错误日志），返回延迟 < 5ms。这一点比标准 RPC 还快。
- 风险：如果 bundle-proxy 立即返回成功但 builder 实际拒绝（无效 tx 等），客户端
  收到的"成功"是误导的。**Mitigation**：bundle-proxy 在转发前做基本校验（chainId
  正确、nonce 不过低、gas 足够），失败立即返客户端原始错误码。

#### ⚠️ blockNumber offset 必须 ≥ 10（Phase 1.6 实测教训）

```js
// ❌ 错的（spammer.js Phase 1.5 默认值）
bundle.blockNumber = toHex(cachedHead + 1n)   // 1 秒后过期

// ✅ 对的
bundle.blockNumber = toHex(cachedHead + 10n)  // 10 秒消化窗口
```

**为什么必须 ≥ 10**：

op-rbuilder 收到 bundle 后会检查 `blockNumber`，**当前 head > bundle.blockNumber
时会 silent drop**（不打包，但 RPC 仍返 200 OK，客户端拿到 tx hash）——这是比
"明确 fail-fast"更糟糕的失败模式：用户拿到 hash 但永远不上链。

Phase 1.6 多进程测试实测：
- `OFS=1`（head+1）：inclusion **36.8%**（60% 因排队过期被 drop）
- `OFS=30`（head+30）：inclusion **43.2%**（仍不到 100%，但救回 15%）

`head+10` 是 throughput 和 builder mempool 占用之间的折中：
- 太小（<5）：高负载下 silent drop 抬升用户投诉
- 太大（>30）：builder 内部要 hold 更多 bundle 等过期，增加内存占用

### 3.3 fail-fast 策略

```
on incoming eth_sendRawTransaction:
  if inflight_count >= MAX_INFLIGHT:
    return jsonrpc-error -32005 "Service overloaded, retry later"
    metric: rejects_total{reason="overload"}++
    HTTP status: 429 Too Many Requests
  else:
    inflight_count++
    forward()
    on response (or timeout): inflight_count--
```

**阈值取值**（基于 Phase 1.5 实测）：

| 阈值 | 行为 |
|---|---|
| `MAX_INFLIGHT=1000`（默认）| 800 TPS 下平均 in-flight 16-20，永远不会触发；1500+ 时立刻 reject |
| 软警告：`MAX_INFLIGHT * 0.8` | 触发 metric `proxy_inflight_high_watermark`，提前告警 |
| 超时：`UPSTREAM_TIMEOUT_MS=5000` | 单次 RPC 等 5s 还没回直接 reject + 释放 in-flight 槽位（防 builder 卡死的连锁反应）|

### 3.4 keep-alive 强制启用

bundle-proxy 自身：
- 上游连接（→ op-rbuilder / flashblocks-rpc / op-geth）：undici Agent，
  `connections=64`、`pipelining=12`、`keepAliveTimeout=60_000`
- 下游连接（← dApp）：HTTP/1.1 keep-alive 默认开（Express/Fastify 都是默认 yes）
- 暴露 `Connection: keep-alive` 头给 dApp

---

## 4. 实现选型

### 4.1 语言：Node.js（fastify）

理由：
1. 跟 mychain 现有 `dev/bots/*` 工具链统一（都是 Node.js + viem）
2. fastify 在 1000-5000 RPS 区间足够（远超 800 TPS 目标），且开箱即用 prometheus
   exporter
3. 团队成员熟悉 Node 调试，PoC 阶段迭代快

不选 Go/Rust 的原因：性能溢出（800 TPS 用 Node 已经够用），但维护门槛升高。
**如果未来需要 5000+ TPS，再考虑 Go 重写**。

### 4.2 关键依赖

```json
{
  "fastify": "^4.x",
  "undici": "^6.x",     // 上游 keep-alive agent
  "prom-client": "^15.x" // metrics
}
```

### 4.3 文件结构

```
dev/bundle-proxy/
├── package.json
├── README.md
├── server.js          // 入口
├── lib/
│   ├── router.js      // method 路由表（§3.1）
│   ├── bundleAdapter.js  // raw tx → bundle 转换 + tx hash 计算
│   ├── upstream.js    // undici Agent + RPC client
│   ├── inflight.js    // in-flight counter + fail-fast
│   ├── headCache.js   // blockNumber 500ms 缓存
│   └── metrics.js     // prometheus 指标
└── Dockerfile
```

### 4.4 监控指标

```
# 转发吞吐
proxy_requests_total{method, upstream, result}      # success / error / reject

# in-flight 实时数
proxy_inflight_count

# 拒载计数
proxy_rejects_total{reason}                         # overload / timeout / invalid

# RPC 延迟分布
proxy_request_duration_seconds{method, upstream}    # histogram

# bundle 转发结果
proxy_bundle_forward_total{result}                  # ok / builder-error / network-error
```

---

## 5. state 迁移路径

mychain 现有 dev chain 状态：50k 钱包 + 1000 个 ERC-20 token 合约 + CGT v2 + L1↔L2 bridge contracts。

op-rbuilder 是 reth fork，state 跟 op-geth **协议兼容**（OP Stack 同 chain ID 同
genesis 同 hardfork），但**物理 db 格式不同**（geth: pebble；reth: mdbx）。

### 5.1 三种迁移策略

| 策略 | 操作 | 优点 | 缺点 |
|---|---|---|---|
| **A. fresh chain，重建 state** | 新 chainId 起新链，重 deploy 合约 + 重 mint token + 重新 fund 50k 钱包 | 干净、确定 | dev 数据丢，业务方需要接受 |
| **B. genesis allocs 导入** | dump op-geth state → 转 OP Stack genesis allocs → reth `init --chain genesis.json` | 保留状态 | 需要写 dump 脚本，50k 账户 alloc 文件可能 100+ MB |
| **C. P2P 双 EL** | op-geth 和 op-rbuilder 同时跑，op-rbuilder 通过 op-node `op_engine` 分发跟上 | 不停链 | 配置复杂；op-rbuilder 没有 P2P sync from geth 的现成路径，需要 verifier 模式 |

### 5.2 推荐：策略 A（fresh chain）

理由：
1. dev 链状态本来就是反复重置的（每次跑 `make stack-down stack-up` 就重建）
2. 业务方关心的是"压测能跑出 800 TPS"，不是"现有 dev 状态"
3. Phase 2 验证完毕后，正式上 testnet/mainnet 时也是 fresh chain（v7）

具体步骤（Phase 2 实施时细化）：
- 复制 `dev/scripts/01-deploy.sh` → `dev/scripts/01-deploy-flashblocks.sh`，把
  op-geth 替换成 op-rbuilder
- L1 anvil + op-deployer 流程不变
- mint 50k 钱包 + 1000 token 的脚本不变（用 tokenspammer 跑就行）

---

## 6. 失败回滚

### 6.1 bundle-proxy crash

`docker-compose.flashblocks.yml` 不要把 dApp 8545 端口暴露给宿主，仍由 op-geth
占着。bundle-proxy 跑在内部网络，crash 时 op-geth 顶住正常 RPC（虽然 TPS 回落到
180 baseline）。

### 6.2 op-rbuilder crash

bundle-proxy 检测到 builder 5xx 或 timeout：
1. metric `proxy_bundle_forward_total{result="builder-error"}++`
2. fallback：把 raw tx 直接转发到 op-geth `eth_sendRawTransaction`（**不**再包装
   bundle，因为 op-geth 不支持 bundle）
3. 在 builder 恢复前所有流量走 op-geth，TPS 回落但服务不中断

需要 health check + circuit breaker（fastify 中间件层加）。

### 6.3 整套 Flashblocks 弃用

`docker-compose.flashblocks.yml` 是独立文件，停掉后 stack 回到 v6 baseline 完全
不影响。这是 §6.1 选 Flashblocks 的根本理由——**回滚成本极低**。

---

## 7. 实施 Milestone

### M1：bundle-proxy 单元开发（不依赖 op-rbuilder）

- [ ] `server.js` + `router.js` 雏形
- [ ] `bundleAdapter.js` + 单测（raw tx → bundle，tx hash 计算）
- [ ] `inflight.js` + fail-fast 单测
- [ ] **集成测**：mock op-rbuilder 用一个 echo server，跑 800 TPS 看 bundle-proxy
      自身是否瓶颈

### M2：connect 到 chain-test2 已有 builder-playground stack

- [ ] bundle-proxy 启动指向 chain-test2 的 op-rbuilder :8547
- [ ] 把 `flashblocks-spammer` 改成调 bundle-proxy（用 eth_sendRawTransaction）
      而不是直接 sendBundle
- [ ] 跑 ladder 800/1000/1500，对比 §12.2 的数字
- [ ] **验证**：
  - bundle-proxy 自身 ≤ 5ms 延迟开销
  - 800 TPS 0% reject
  - 1500 TPS reject 率达 30-50%（fail-fast 起作用）
  - 单 sender 拿到 429 后 backoff 重试能正常工作

### M3：mychain 自己起 op-rbuilder + rollup-boost

- [ ] `dev/docker-compose.flashblocks.yml`：op-rbuilder + rollup-boost +
      flashblocks-rpc + bundle-proxy
- [ ] `dev/scripts/01-deploy-flashblocks.sh`（fresh chain，新 chainId 或同 chainId
      重置）
- [ ] `make stack-up-flashblocks` Makefile target
- [ ] **验证**：mychain 自己起 stack 后跑同款 ladder，结果与 chain-test2 一致

### M4：head-to-head 对比

- [ ] tokenspammer 跑同款 stress-soak 200/500/800 TPS
- [ ] 对比 v6-failfast-baseline：稳态 TPS、fail-fast 行为、长跑稳定性
- [ ] 数据汇总到 `STRESS_TEST_REPORT_V7.md`

### M5：长跑 + 风险接受

- [ ] 800 TPS soak 24 小时
- [ ] §3.2 关键问题清单逐条 close
- [ ] STRESS_TEST_REPORT_V7 §12.4（10 个坑）逐条 verify

---

## 8. 待决策项

### 8.1 bundle-proxy 是否需要冗余（HA）？

dev 阶段不需要。生产阶段需要 nginx upstream 多实例 + health check。
**决定**：先做单实例，HA 留给 Phase 3 决策合并阶段。

### 8.2 fail-fast 阈值用 in-flight 还是 RPS？

- **in-flight**：实现简单，对 builder 真实瓶颈反应快
- **rolling RPS window**：更直觉，但需要 sliding window 算法

**决定**：默认 in-flight 1000，**同时**暴露 RPS 限制（`MAX_RPS=1500` 默认禁用），
后期看实际生产场景再切换。

### 8.3 read RPC 是路由到 flashblocks-rpc 还是 op-geth？

| 用户场景 | 期望视图 | 路由 |
|---|---|---|
| dApp 立即看到自己刚发的 tx 状态 | pre-confirmation | flashblocks-rpc |
| 浏览器查 finalized block / receipt | finalized | op-geth |
| 监控/索引服务 | finalized | op-geth |

**决定**：见 §3.1 表格，按 method 分流。bundle-proxy 维护两个上游 client，根据
方法路由。

---

## 9. 风险

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| bundle-proxy 自身成为瓶颈 | 低 | 高 | M1 集成测先量过 800 TPS 自身延迟 ≤ 5ms |
| op-rbuilder v0.2.x 升级新版后 bundle 接口变了 | 中 | 中 | 锁定镜像版本；新版升级走独立 PR |
| dApp 的 SDK 在收到 429 后不退避 | 中 | 中 | 文档明确写"必须实现指数退避"；同时 proxy 侧加 `Retry-After` 头 |
| state 迁移策略 A 业务方不接受 | 低 | 高 | 备用策略 B（genesis allocs）已论证可行 |
| 链上 ERC-20 transfer（带 signature recovery）的真实 tx gas > native transfer，800 TPS 跑不出来 | 中 | 高 | M2/M4 必须用 ERC-20 spammer 复测，不只 native transfer |

---

## 10. 文档维护

实施过程中遇到的新坑、配置调整、性能数据，都追加到 §11 实施日志（待补）。
完成后写完整 retrospective 到 `STRESS_TEST_REPORT_V7.md`。
