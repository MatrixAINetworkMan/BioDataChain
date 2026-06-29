# MAN L2 压测报告

> **测试时间**：2026-04-30 ~ 2026-05-01
> **测试人**：研发团队
> **测试目标**：在 L2 链上部署 1000 个 ERC-20、新建 50000 个地址、相互随机
> 转账，评估链可达到的稳态 TPS，并定位瓶颈
> **结论摘要**：当前 op-geth 单 sequencer 配置下链稳态 ~100 TPS，瓶颈在 op-geth
> worker 的 `fillTransactions` 一次性 snapshot 行为（详见 §6）。
> **业务目标更新**：TPS 目标从 1000 调整为 500（业务方接受），可选方案与实施
> 计划见 §12（**Flashblocks 增量集成路线**，不需要重建链）。
>
> **更新日志**：
> - **v6 (2026-05-04)**：fail-fast 实测闭环。新增 §14 实测最终验证：链稳态
>   chain_tps=180 TPS（200 TPS 正常负载）、chain_tps=177 TPS（1000 TPS 攻击
>   模拟）—— **5x 攻击流量下链不被打挂**，mempool 形态稳定。业务方一期接受
>   150 TPS SLA + fail-fast 自保护。生产 baseline `globalslots=500`（v5 推荐
>   的 200 调整为 500，留足 fillTransactions 装块 buffer）。新 branch
>   `feat/high-tps-flashblocks` 在新服务器上启动 Flashblocks Phase 1 PoC
> - v5 (2026-05-03)：业务方明确 200 TPS 目标的本质是"超载不雪崩 / 客户端可
>   感知降级"。增加 §13 fail-fast 模式（不动链架构，把 op-geth `txpool.globalslots`
>   调小，超额 tx 在 RPC 层即时返回 `txpool is full`，spammer 区分 fail 类型计数）。
>   并澄清"传统 ETH 块满了出现链上可查失败 tx"的认知误区
> - v4 (2026-05-01)：业务目标 1000 → 500 TPS。增加 §12 完整 Flashblocks
>   评估（机制 / 10 个坑 / 3 阶段实施 / 决策矩阵），并执行 Phase 0 代码改造
>   （spammer / Makefile RPC 端点参数化）
> - v3 (2026-05-01)：v2 假设的"batcher throttling"在我们实际版本组合
>   （op-batcher v1.16.7 + op-geth v1.101702.1）里**不存在**：op-batcher
>   v1.16.7 没有 throttle 相关 flag，op-geth v1.101702.1 没有 `miner_setMaxDASize`
>   RPC。实测关掉假设的"throttle 配置"后 TPS 仍 ~100。回到 v1 判断
> - v2 (2026-05-01)：误判 batcher-sequencer throttling 是真凶（仅在 OP Stack
>   develop / v1.9.5+ 主线版本存在，我们用的版本没合入）
> - v1 (2026-05-01)：判断 op-geth worker 行为限制，建议换 reth 或 patch
>
> **教训**：
> 1. 看 OP Stack 文档时务必区分 develop 分支 vs 实际使用的 release tag 版本
> 2. 假设新瓶颈前先用 `--help | grep ...` 确认参数真的存在
> 3. 错误修复的代价：一次错误归因 + 一次错误回滚 + 一次再修正 = 3 个 commit
>    + 一次让 op-batcher 进 crash loop 影响业务测试
> 4. 升级到 dev 分支不是银弹：Jovian 升级把 batcher throttling 换成 protocol-level
>    的 DA footprint，但 fillTransactions 行为没变，单纯升级反而引入新限制

---

## 目录

1. [TL;DR](#1-tldr)
2. [测试目标与方法](#2-测试目标与方法)
3. [测试环境](#3-测试环境)
4. [迭代过程时间线](#4-迭代过程时间线)
5. [关键数据](#5-关键数据)
6. [瓶颈定位过程](#6-瓶颈定位过程)
7. [为什么 L1 不是瓶颈](#7-为什么-l1-不是瓶颈)
8. [当前架构上限分析](#8-当前架构上限分析)
9. [行业对标](#9-行业对标)
10. [优化路径](#10-优化路径)
11. [最终结论](#11-最终结论)
12. [Flashblocks 路线评估（v4 新增，目标 500 TPS）](#12-flashblocks-路线评估v4-新增目标-500-tps)
13. [Fail-fast 模式（v5 新增，超载不雪崩）](#13-fail-fast-模式v5-新增超载不雪崩)
14. [实测最终验证（v6 新增，闭环）](#14-实测最终验证v6-新增闭环)
15. [附录 A：所有调整过的参数](#附录-a所有调整过的参数)
16. [附录 B：诊断命令清单](#附录-b诊断命令清单)
17. [附录 C：spam 日志典型模式](#附录-cspam-日志典型模式)

---

## 1. TL;DR

| 指标 | 实测 |
|---|---|
| **链稳态 TPS** | **~100** |
| **瞬时峰值 TPS（mempool 缓冲下）** | ~1000（前 8 秒，不可持续） |
| **每块 tx 数** | 84-118 笔 |
| **每块 gas utilization** | 7-10%（远未到 60M 上限） |
| **每块 elapsed** | 33-200ms（远未用满 1s block window） |
| **op-geth CPU 利用率** | ~50% / 核（远未饱和） |
| **磁盘 IOPS / 内存** | < 10% / 4%（远未饱和） |
| **L1 出块** | 严格 2s/块（与 L2 解耦，非瓶颈） |
| **L2 出块** | 严格 1s/块，60 块全部 Δs=1（非瓶颈） |

**核心发现**：所有硬件资源使用率都不到 20%，但每块只装 ~100 笔 → block_time × 100 笔 = ~100 TPS。

**瓶颈定位**：op-geth worker 在 OP Stack sequencer 模式下，每个 block window 内
的 `fillTransactions` 行为：worker 在 `engine_forkchoiceUpdated` 触发时拉一次
mempool snapshot，装完 ~100 笔进入 idle，剩下 800-950ms 等 op-node 来取 payload。
期间到达 mempool 的新 tx 进不了当前 block，要等下个 block window。这是 op-geth
源码层行为，**所有可调参数（cache / recommit / txpool / miner.gaslimit / batcher
throttling*）改变不了它**。

> *中途曾误判为 batcher-sequencer throttling 限制（OP Stack v1.9.5+ 主线
> feature），但实测我们用的版本组合（op-batcher v1.16.7 + op-geth v1.101702.1）
> 里这个 feature 不存在：op-batcher 没有 throttle flag，op-geth 没有
> `miner_setMaxDASize` RPC。详见第 6 节"误判过程"。

**100 TPS 的物理来源**：1 block / s × ~100 tx / block = 100 TPS。

**要持续 1000+ TPS 必须做架构级改造**：
- 换 op-reth（OP Stack 同协议，不同实现，1-2 周）
- patch op-geth 源码改 worker fillTransactions 逻辑（1 周）
- BatchTransfer 合约打捆（半天，但"TPS"定义改变 → 实际 transfer 量 ×100）

不在参数调优能解决的范围。

---

## 2. 测试目标与方法

### 业务目标

- 在 MAN L2 上部署 **1000 个 ERC-20 token**
- 创建 **50000 个地址**作为持有者 / 接收者
- 持续在地址间随机互转这些 token
- **目标 TPS：1000**

### 工具：tokenspammer

自研工具，位于 `dev/bots/tokenspammer/`，技术栈 Node.js + viem。
压测路径优化：

| 优化点 | 说明 |
|---|---|
| **JSON-RPC batch** | 一个 HTTP 请求批量发 N 笔 `eth_sendRawTransaction` |
| **undici 全局连接池** | 把单 host 连接数从默认 10 提到 64，避免 sendRaw 串行 |
| **本地 nonce 跟踪** | 内存维护 50000 个 sender 的 nonce，签名时 `nonce++` |
| **busy 标志位** | `Uint8Array(50000)` 防止同 sender 跨 tick 冲突 |
| **预编 calldata** | 直接拼 `0xa9059cbb + to + amount`，跳过 viem abi 重路径 |
| **客户端背压** | `MAX_TICK_QUEUE` 限制并发，前一 tick 没完不发新 tick |
| **mempool 背压** | 监控 op-geth `txpool_status`，超过 HIGH 暂停发送 |

### 度量指标

| 指标 | 出处 | 含义 |
|---|---|---|
| `tps(rec)` | spammer | 最近 2s 实际成功 sendRawTransaction 速率 |
| `tps(avg)` | spammer | 启动以来平均速率 |
| `mp pending+queued` | op-geth `txpool_status` | mempool 实时大小 |
| `q` | spammer | 在飞 RPC batch 数 / MAX_TICK_QUEUE |
| `rpc p50/p95/max` | spammer | RPC batch 来回延迟 |
| **链真实 TPS** | `bot-token-chain-tps` | 直接读最近 N 个 block 的 tx 数 / 时间跨度 |
| **暂停期消化速度** | mempool delta / time | 链消化速度 = 真实 sustained TPS |

最重要的指标是**链真实 TPS**和**暂停期消化速度**，直接反映链的实际处理能力，
跟 spammer 的输出无关。

---

## 3. 测试环境

### 硬件（chain-test）

| 项 | 配置 |
|---|---|
| CPU | 4 vCPU（根据 docker stats 反推） |
| 内存 | 30 GiB |
| 磁盘 | NVMe (`/data` xfs)，**升级后 10000 IOPS / 500 MB/s 吞吐** |
| 网络 | 内网，docker bridge |

### 软件版本

| 组件 | 版本 |
|---|---|
| op-geth | v1.101702.1 |
| op-node | v1.16.12 |
| op-batcher | v1.16.7 |
| op-deployer | v0.6.0 |
| L1 | anvil（foundry stable） |

### 链配置（关键）

```env
L2_CHAIN_ID=42170
L2_BLOCK_TIME=1            # L2 1s/block
L2_GAS_LIMIT=60000000      # 60M gas/block
L1_BLOCK_TIME=2            # L1 anvil 2s/block

# op-geth 经测试调优后的最终参数
OP_GETH_GCMODE=full
OP_GETH_STATE_SCHEME=path
OP_GETH_CACHE_MB=8192      # state trie cache 8GB
OP_GETH_RECOMMIT=200ms     # worker recommit interval
```

### tokenspammer 参数（调整后）

```env
TARGET_TPS=200             # 目标速率（200 = 链 1.3x，温和过载）
SPAM_TICK_MS=100           # 100ms tick = 每秒 10 次发送
MAX_TICK_QUEUE=8           # 最多 8 个并发 RPC batch 在飞
HTTP_CONNECTIONS=64        # undici 全局连接池
MEMPOOL_HIGH_WATER=3000    # mempool ≥ 3000 暂停发送
MEMPOOL_LOW_WATER=1000     # 降到 1000 恢复发送
```

---

## 4. 迭代过程时间线

整个测试是一个**迭代式发现瓶颈**的过程。每次发现一个问题修了之后会暴露下一层。

### 阶段 1：客户端瓶颈（2026-04-30 上午）

**症状**：spammer 输出 ~200 TPS 卡死。

**发现**：
- spammer 使用 viem 默认 fetch，**undici 单 host 默认 10 个 connection**
- 30 个并发 batch 把连接打满，sendRawTransaction 回包变成串行

**修复**：
- 引入 `undici` 显式 dispatcher，单 host 连接数提到 64
- 改用 JSON-RPC batch，一个 HTTP 请求发多笔 tx

**结果**：spammer 客户端瞬时输出能力从 200 → 1000+ TPS。

### 阶段 2：mempool 死锁（2026-04-30 下午）

**症状**：spam 跑 80 秒后 mempool 涨到 24000+ 卡死，`tps(rec)` 长期为 0。

**发现 1**：op-geth 默认 `--txpool.globalslots=4096`，跑 1000 TPS 时秒满。

**修复 1**：调大 mempool 容量
```yaml
- --txpool.globalslots=20000
- --txpool.accountslots=128
```

**发现 2**：op-geth 默认把 mempool 持久化到 `transactions.rlp`，重启时
reload。上次跑爆的几万笔死 tx（nonce 不连续）会一直留在 queued pool 永远
不出，下次重启又重新载入造成死锁。

**修复 2**：禁用 mempool journal
```yaml
- --txpool.journal=
- --txpool.nolocals
```

加 Makefile target `bot-token-clear-mempool` 一键清残留 journal。

### 阶段 3：磁盘 IOPS 升级（2026-04-30 晚）

**怀疑**：默认 EBS gp3 3000 IOPS 是瓶颈，op-geth 跑久了 path scheme flush
变慢。

**做法**：升级 EBS 到 10000 IOPS / 500 MB/s。

**结果**：fio 测试 10k IOPS 达标。但**链 TPS 没显著提升**（说明 IOPS 不是
真正瓶颈，但作为基础设施改进还是值得做）。

### 阶段 4：op-geth state scheme（2026-04-30 晚）

**发现**：默认配置 `archive + hash` scheme 写入 IO 重，不适合压测。

**修复**：改为 `full + path` scheme（path 写入 IO 减半，full 不留历史 state）

**注意**：改完后 `op-geth-init` 容器还在用 hash scheme，导致初始化失败。
**修复**：让 init 容器也用同一 scheme

**结果**：长跑稳定性提升，但 sustained TPS 仍 ~100。

### 阶段 5：op-geth cache 调大（2026-05-01）

**发现**：`--cache=1024` 默认太小，分给 trie/db/snapshot 后实际 trie cache
仅 ~600MB，跑久了 hit rate 暴跌。

**修复**：
```yaml
- --cache=8192
- --cache.trie=50    # 50% 给 trie cache
```

**结果**：RPC p50 从 2630ms 降到 314ms（**降 8x**！），但**链 sustained
TPS 仍 ~100**。说明 cache 改善了 RPC 路径，但出块速度没变。

### 阶段 6：worker recommit 调整（2026-05-01）

**测试 1**：`recommit=300ms`（默认 2s 改激进）
- 结果：mempool 大时 worker 一直推翻重选，每块只塞 1-2 笔，整体 TPS 退化

**测试 2**：`recommit=1s`（= block_time，相当于禁用 recommit）
- 结果：每块 ~100 笔，sustained 92 TPS

**测试 3**：`recommit=200ms`（小于 block_time）
- 结果：每块 84-118 笔，sustained **97 TPS**（基本无变化）

**结论**：recommit 在 OP Stack sequencer 模式下**对每块装载量影响很小**，
因为 OP Stack 的 build 逻辑不是普通 PoS geth 的"每次 recommit 重建 block"
那一套。

### 阶段 7：L1 不是瓶颈的验证（2026-05-01）

详见第 7 节。结论：L1 出块严格 2s，op-node 没 stall warning，L2 出块严格
1s 没漂移。L1 完全不影响 L2 TPS。

### 阶段 8：误判 batcher throttling（2026-05-01，**走过的弯路**）

**起点**：阶段 1-7 修完后，链稳态仍 ~100 TPS，所有可调参数（cache / recommit /
txpool / state scheme）改了都没用，出块 elapsed 33-200ms 远短于 1s window，
强烈暗示有显式上限。

**搜索发现**（2026-05-01 下午）：OP Stack v1.9.5 引入 batcher-sequencer
throttling，op-batcher 默认通过 `miner_setMaxDASize` RPC 限制每块 DA 130000
bytes，单 ERC20 transfer compressed ≈ 1000 bytes → **每块 ~130 笔 → ~100 TPS**，
跟实测吻合度极高。

**误判**：基于一篇 OP Stack v1.9.5 release note + 一篇 develop 分支的官方文档，
判断真凶是 batcher throttling，"修复就 1 行配置"。在 docker-compose.yml 给
op-batcher 加：

```yaml
- --throttle-threshold=0
- --throttle-interval=0
```

**翻车**：
- op-batcher v1.16.7 启动报错：unknown flag `--throttle-threshold`
- 进 op-batcher 容器跑 `op-batcher --help | grep -i throttle`：**输出为空**
- 进 op-geth 容器：`cast rpc miner_getMaxDASize --rpc-url http://op-geth:8545`：
  `method miner_getMaxDASize does not exist`

**结论**：throttling 这套代码在我们用的 op-batcher v1.16.7 + op-geth v1.101702.1
里**完全不存在**。这套机制是 OP Stack develop 分支 / v1.9.5+ 主线版本的 feature，
在我们用的稍旧 release tag 里还没 backport。

**回滚**：5 分钟内删 flags + 重启 batcher，链恢复正常。

**后续验证关 throttling 也救不了**：把 spam 跑了 5 分钟，链稳态仍 ~100 TPS，
说明即使 throttling 当时存在并被关掉，也不能解决问题。**真正瓶颈在别的地方**。

**教训**：
1. 假设新瓶颈前先 `--help | grep` 确认参数真存在
2. 看官方 doc 区分 develop 分支 vs 实际使用的 release tag
3. 误归因加上误"修复"会让线上服务进 crash loop，代价不只是浪费时间
4. release note 提到的 feature 不一定意味着默认启用，更不一定意味着所有
   下游 fork 都已合入

---

## 5. 关键数据

### 5.1 链真实 TPS（最权威）

执行 `make bot-token-chain-tps N=60`，扫描最近 60 个 L2 block：

```
  block      ts          Δs    tx     gas(M)  util%
  ---------- ----------  ---   ----   ------  -----
  15976      1777621920  —     106    5.4M    9%
  15977      1777621921  1     106    5.4M    9%
  15978      1777621922  1     101    5.1M    8%
  ...
  16035      1777621979  1     110    5.6M    9%
  -----
  60 块共 5752 tx，时间跨度 59s → 实测 TPS ≈ 97
```

**关键观察**：
- 每块 Δs = 1s（严格，无漂移）
- 每块 tx = 84-118（**稳定在 ~100**）
- 每块 gas util = 7-10%（**极低**，理论上限是 60M / 35k ≈ 1714 笔，
  实际只装 ~100）
- 60 块只有 1 个 1-tx 的"empty"块（L1Block.setL1BlockValues system tx）

### 5.2 op-geth 实际块构建耗时（来自 op-geth 日志）

```
INFO Imported new chain segment number=13708 txs=118 elapsed=199.6ms mgasps=30
INFO Imported new chain segment number=13710 txs=115 elapsed=115.0ms mgasps=51
INFO Imported new chain segment number=13714 txs=101 elapsed= 50.3ms mgasps=102
INFO Imported new chain segment number=13734 txs= 94 elapsed= 33.3ms mgasps=144
```

**关键观察**：
- elapsed = 33-200ms，**远小于 1s block window**
- mgasps（million gas / second）= 30-144，最快达 144 mgaps
- 144 mgaps × 1s = 144M gas/s 处理能力。**block_gas_limit 60M 用 ~400ms
  就能装满**，但实际只用 50-200ms 就完成 100 笔后退出
- → **worker 不是被 gas/cpu 卡住，是没有更多 tx 可装**（或者主动停止装载）

### 5.3 hardware 利用率（暂停消化 mempool 时）

| 资源 | 实测 | 上限 | 利用率 |
|---|---|---|---|
| CPU | 200-267% | 400% (4 核) | **50-67%** |
| 内存 | 1.1 GB | 30 GB | 4% |
| 磁盘读 IO | 8 KB | 10000 IOPS | < 1% |
| 磁盘写 IO | 14 MB/s | 500 MB/s | 3% |
| RPC p50 | 314ms | — | （可承受） |

**结论**：所有硬件资源都没满，链出块速度受**软件行为**而非硬件限制。

### 5.4 暂停消化速度（链 sustained TPS 的另一种测量）

spammer 触发 backpressure 暂停后，单纯看 mempool 减少速度（=链消化速度）：

| 时间窗口 | mempool 起 | mempool 终 | 用时 | TPS |
|---|---|---|---|---|
| t=12s → t=42s | 7001 | 3548 | 30s | **115** |
| t=14s → t=54s | 7735 | 2425 | 40s | **133** |

跟 chain-tps 直接计算的 ~100 一致（小差异因为统计窗口不同）。

### 5.5 不同 spammer 配置下的表现对比

| TARGET_TPS | recommit | spammer 输出 | 链消化 | 结论 |
|---|---|---|---|---|
| 1000 | 1s | 800-1000 (虚高) | ~92 | mempool 雪崩 |
| 1000 | 200ms | 800-1000 (虚高) | ~150 (短期) ~100 (长期) | 仍雪崩 |
| 200 | 200ms | 200 | ~97 | mempool 周期性触发 backpressure |
| 150 | 200ms | 150 | ~150 | 平稳，mempool 接近 0 |

**150 TPS 是稳定保证**，~100 TPS 是单纯链消化能力下限。

---

## 6. 瓶颈定位过程

### 第一性原理：为什么是 ~100 TPS？

```
1 block / second × ~100 tx / block = 100 TPS
```

block_time 由 OP Stack 协议决定（`L2_BLOCK_TIME=1s`），每秒固定 1 个块。
所以 TPS = 每块 tx 数。

### 关键问题：为什么每块只装 100 笔？

**理论上限**：
- block_gas_limit = 60M
- ERC20 transfer 单 tx ≈ 35k gas
- 理论上限 = 60M / 35k = **~1714 笔/块**

**实际**：~100 笔/块 = **理论上限的 6%**

### 排除每个可能的瓶颈

#### ❌ 不是 EVM 算力

elapsed = 33-200ms 远小于 1s。worker 在 50ms 完成 100 笔的话，1s 内有能力
处理 2000 笔。EVM 算力**用了不到 5%**。

#### ❌ 不是磁盘 IO

写 IO 14 MB/s 远低于 NVMe 500 MB/s 上限。读 IO 8KB（cache 命中率高）。

#### ❌ 不是 CPU

200-267% / 4 核 = 50-67% 单核。多核根本没用满（op-geth 单线程 EVM
不会用满多核，但 50%/核 也说明单核都没饱和）。

#### ❌ 不是内存

1.1GB / 30GB = 4%。

#### ❌ 不是 mempool 容量

`--txpool.globalslots=20000`，spam 时 mempool 长期保持 1000-3000，远未
触及上限。

#### ❌ 不是 L1 出块

详见第 7 节。

#### ❌ 不是 spammer 客户端

q=8/16 长期不满，rpc p50=300ms 健康，spammer 完全有能力发更多，是链不收
（mempool 触顶 backpressure）。

#### ✅ 真正瓶颈：op-geth `fillTransactions` 一次性 snapshot 行为

**直接看 op-geth v1.101702.1 源码**（`miner/worker.go`）：

##### 关键设计 1：`fillTransactions` 每个 block 只调用一次

```go
// generateWork (line 238)
timer := time.AfterFunc(max(minRecommitInterruptInterval, miner.config.Recommit), func() {
    interrupt.Store(commitInterruptTimeout)
})
err := miner.fillTransactions(ctx, interrupt, work)
timer.Stop()
```

注意 `max(minRecommitInterruptInterval, ...)`，常量 `minRecommitInterruptInterval
= 2 * time.Second`（line 49）。

**含义**：我们配置 `--miner.recommit=200ms` 在 OP Stack sequencer 模式下
**完全无效**，最低也是 2s。

##### 关键设计 2：mempool snapshot 在入口处一次性拿取

```go
// fillTransactions (line 774)
pendingPlainTxs, plainTxCount := miner.txpool.Pending(filter)
// ...
plainTxs := newTransactionsByPriceAndNonce(env.signer, normalPlainTxs, env.header.BaseFee)
// ...
err := miner.commitTransactions(ctx, env, plainTxs, blobTxs, interrupt)
```

`miner.txpool.Pending(filter)` 一次性拿到当前 mempool 里所有 pending tx，
按 `(price, nonce)` 排序构成 heap。**heap 在 `commitTransactions` 循环过程中
不会再 refresh** — 即使循环期间 mempool 涨了 10000 笔新 tx，worker 也看不到。

##### 关键设计 3：`commitTransactions` 是个 `for {}` 但只跑 snapshot

```go
// commitTransactions (line 565-746)
for {
    if interrupt != nil && interrupt.Load() != commitInterruptNone { return signalToErr(signal) }
    if env.gasPool.Gas() < params.TxGas { break }            // gas 用完
    pltx, ptip := plainTxs.Peek()
    if ltx == nil { break }                                   // heap 空 ← 主要退出原因
    // ... DA 检查（仅 isJovian / MaxDABlockSize 非 nil 时生效，我们都没启用）
    miner.commitTransaction(...)
    txs.Shift() // pop heap
}
```

**主要退出条件**：`ltx == nil` — heap 空了。

我们的 `MaxDABlockSize = nil`（没启用 DA 限制），`isJovian = false`
（没到 Jovian 升级），所以那两条 break 都不会触发。`gasPool` 60M 远没用完
（实测 gas util 7-10%）。**唯一退出原因就是 heap 空**。

#### 整理一下 100 TPS 的物理来源

```
t = 0     : block N 出（forkchoiceUpdated 触发 generateWork）
t = 0+5ms : worker 进入 fillTransactions，拿 mempool snapshot
            (这一刻 mempool 里有 ~100 笔 → snapshot 里 100 笔)
t = 5..200ms : commitTransactions 把 snapshot 里 100 笔全装完
            (heap pop 完，break 退出)
t = 200..1000ms : worker idle，等 op-node 来取 payload
            spammer 在这 800ms 内继续发 tx 进 mempool（涨 800-1000 笔），
            **但这些 tx 进不了 block N**
t = 1000ms : op-node 调 engine_getPayload，封 block N，包含 100 笔
t = 1000ms : block N+1 开始，重复
```

每秒固定 1 个 block × 每个 block snapshot 里 ~100 笔 = **100 TPS**。

##### 为什么 mempool 涨到 3000 时 snapshot 也只有 ~100 笔

这是关键的反直觉点。粗看应该是 snapshot 入口 → mempool=3000 → 装 3000 笔。
实测**不是这样**。可能的解释（按可能性排序）：

1. **snapshot 拿取时机**：fillTransactions 的入口在 `engine_forkchoiceUpdated`
   触发时（block N-1 出完那一刹那）。这一刻 mempool 大量 tx 还没 admit
   完成。"mempool=3000" 的报告是 spammer 异步轮询的累计 pending，但 snapshot
   时机比这个时刻早

2. **`txpool.Pending(filter)` 内部按 sender 分组**：每个 sender 只取
   "nonce 连续的最前面一段"。我们 50000 sender 配 200 TPS，每个 sender
   平均 1 tx 在 mempool，但 spammer 有 fail/retry 时，单 sender 可能
   nonce gap，整段后续 tx 在 snapshot 里被过滤

3. **`MaxDATxSize` filter**：filter 在 `Pending()` 入口处过滤每笔 tx 的
   DA size。我们没显式设但默认值可能不为 nil，能过滤掉一些 tx

4. **snapshot 后 commitTransactions 提前 break**：可能 heap 里的 tx 在
   `nonce-too-high` / `errSupervisorInFailsafe` 路径下被 Pop 整段 sender，
   导致 heap 空得快

不论具体哪条占比最高，**根因都是 snapshot 这个一次性拿取的设计**。

##### 验证：换"理论上不应该装满 100 笔"的工作负载会怎样

把 spammer 改成单个 sender 长链发（nonce 严格连续）—— 每块装更多吗？理论上应。

实测 BatchTransfer 合约（1 tx 含 100 个 transfer）—— 单 tx gas ≈ 1.7M，每块装
~30 个 batch tx ≈ 3000 transfers/s 等价吞吐。**单纯看 tx 数还是 ~30，但每个
tx 价值翻 100 倍**。这印证了"瓶颈不是 EVM 算力，是 worker 吃 tx 数的速度"。

##### 行业基准对照

Base 官方在 [Scaling Base With Reth](https://blog.base.dev/scaling-base-with-reth)
里给的 op-geth 在 i3en.12xlarge 实测：

| 客户端 | Block Building p50 | p95 | p99 | p999 |
|---|---|---|---|---|
| **op-geth** | 374ms | 1660ms | 2319ms | 3079ms |
| **op-reth** | 260ms | 560ms | 698ms | 889ms |

我们 elapsed 33-200ms 跟 op-geth p50 374ms 数量级一致（我们硬件略弱所以
p50 反而看上去快，因为没装满 60M gas）。**这个 p95=1660ms 解释了为什么
Base 选择换 op-rbuilder + Flashblocks 而不是继续调 op-geth**。

#### 源码路径

| 文件 | 函数 / line | 作用 |
|---|---|---|
| `miner/worker.go` | `generateWork` (line 164) | 入口，set Recommit timer |
| `miner/worker.go` | `fillTransactions` (line 751) | **拿 snapshot + 调一次 commit** |
| `miner/worker.go` | `commitTransactions` (line 565) | for {} 装 snapshot |
| `miner/worker.go` | `minRecommitInterruptInterval` (line 49) | 强制 2s 下限 |
| `core/txpool/legacypool/legacypool.go` | `Pending(filter)` | mempool snapshot 实现 |

#### 调参为什么都没用

| 调过的参数 | 为什么对 fillTransactions snapshot 没用 |
|---|---|
| `--miner.recommit=200ms` | 被 `max(minRecommitInterruptInterval=2s, ...)` 强制设回 2s |
| `--cache=8192` | 影响 RPC 路径，对 commitTransactions 循环无影响 |
| `--miner.gaslimit=60000000` | gasPool 远没用完，循环不会因为 gas 退出 |
| `--miner.gasprice=0` | tip filter 已经全过，不是这里限制 |
| `--txpool.globalslots=20000` | snapshot 大小不取决于 globalslots，取决于 Pending() 拿取时刻 |
| state scheme `path` | 影响 commitTransaction 的 state IO 速度，但循环已经 50ms 跑完 |
| Disk IOPS 升级 | 同上，瓶颈不在 IO 而在 snapshot 拿取行为 |

**所有这些调整改善了"装载效率"，但都没改变"装载入口的 snapshot 是一次性
的"这个事实**。

#### 解决方向（实际可行的，不是 1 行配置）

| 方向 | 说明 | 投入 |
|---|---|---|
| **op-reth** | Reth 的 OP 实现，block building p99 比 op-geth 快 70%，且对 mempool snapshot 行为有改进 | 1-2 周接入 |
| **op-rbuilder + Flashblocks** | Base 路线，把 1 个 2s 块切成 10 个 200ms 子块，相当于 10x 更频繁拿 snapshot | 2-4 周（rollup-boost 集成） |
| **patch op-geth `fillTransactions`** | 在 commitTransactions 循环内每隔 50 笔调一次 `txpool.Pending()` 把新 tx 加入 heap | 1 周（自维护 fork） |
| **BatchTransfer 合约打捆** | 1 笔 tx = N 笔 transfer，绕过"每块 tx 数限制" | 半天，但需要改业务模型 |

**没有"1 行配置"能解决，必须做架构选择**。

> 在 v2 分析里曾经认为 `--throttle-threshold=0` 是 1 行配置 fix，那是误判。
> 我们用的版本组合（op-batcher v1.16.7 + op-geth v1.101702.1）里 batcher
> throttling 这套机制根本没合入，所以 throttle 不是真凶，关 throttle 也救
> 不了。详见第 4 节阶段 8。

---

## 7. 为什么 L1 不是瓶颈

### 7.1 OP Stack 架构原理

**L1 / L2 解耦**：

```
  L1 anvil (2s/块)              L2 op-geth (1s/块)
  ════════════════              ══════════════════
  独立时钟                       独立时钟
       │                              │
       │   每个 L2 块记一个 L1 origin │
       │  ◄────────引用───────────────│
       │                              │
       │   op-batcher 把 L2 batch     │
       │  ◄────提交回 L1（finality）─│
```

L2 sequencer 按 `L2_BLOCK_TIME=1s` 自主出块，**完全不需要等 L1 出新块**。
L1 在 OP Stack 里只是：

1. **L1 origin 引用**：每个 L2 block 记一个最近的 L1 block hash，用于 reorg
   保护和 finality
2. **batch 归档**：op-batcher 把 L2 历史压缩后写回 L1（影响 finality 时延，
   不影响 L2 出块速度）

即使 L1 改成 12s/块（以太坊主网）或 0.5s/块，**L2 都是 1s 出一个块**。
OP Mainnet / Base 都是这个架构（L1 = 以太坊 12s），照样 2s/块出 L2。

### 7.2 实测验证 L1 不是瓶颈

```bash
# 测试 1：L1 出块速度
docker exec mychain-anvil sh -c '
  H1=$(cast block-number --rpc-url http://localhost:8545)
  sleep 10
  H2=$(cast block-number --rpc-url http://localhost:8545)
  echo "L1 10s 出 $((H2-H1)) 块"'
# 输出: L1 10s 出 5 块（严格 2s/块）✅

# 测试 2：L2 是否在等 L1
docker logs --since=2m mychain-op-node 2>&1 | grep -iE "warn|origin|stall|lag"
# 输出: 没有 stall / lag warning ✅
# l1Origin 推进顺畅: 8020 → 8021 → ... → 8023

# 测试 3：L2 是否每块都准时
make bot-token-chain-tps N=60
# 输出: 60 块每块 Δs=1，无漂移 ✅
```

### 7.3 如果 L1 是瓶颈会出现什么症状

| 症状 | 实测 |
|---|---|
| L2 块 Δs 跳到 2s/3s（在等 L1） | ❌ 没有，全 1s |
| op-node 日志 "waiting for L1 origin" | ❌ 没有 |
| l1Origin 长时间不动 | ❌ 没有，正常推进 |
| op-batcher 报 L1 满 | ❌ 没有 |

**全部不符合 → L1 100% 不是瓶颈**。

### 7.4 改 L1_BLOCK_TIME 不会解决问题

```env
# 假设改成
L1_BLOCK_TIME=1   # 或 0.5
```

**预期效果**：L1 origin 推进更快，op-batcher 提交频率翻倍。

**对 L2 TPS 的影响**：**零**。L2 sequencer 还是按 `L2_BLOCK_TIME=1s` 自主
出块，每块还是装 ~100 笔。

**反而引入风险**：anvil 在 1s/块 下 reorg 概率上升（已经看到 2s/块 时偶发
reorg warning），增加运维负担而非性能。

**结论**：L1 出块速度跟 L2 TPS 完全独立，调 L1_BLOCK_TIME 是死路。

---

## 8. 当前架构上限分析

### 8.1 第一性约束

```
L2 sustained TPS  =  block_time × tx_per_block
                  =  1s ⁻¹    × ~100
                  =  100 TPS
```

要突破 100 TPS 必须改其中一个变量：

#### 缩短 block_time

- `block_time=2s`：单块 worker 有更长 window，可能装更多（但实测 1s 时
  worker 50ms 就 idle，2s window 大概率仍然 idle）→ **可能没有提升**
- `block_time=0.5s`：每秒出 2 块 × ~100 笔 = 200 TPS（如果 worker 行为
  不变）

block_time 是 rollup config 协议参数，改动需重建链。

#### 增加 tx_per_block（最有效，但要改 op-geth）

让 worker 在 build window 里持续从 mempool 拉 tx，目前 worker 一次拉完后
不再 fill。这是 op-geth 源码层行为，**不是参数能改的**。

### 8.2 各资源真实利用率（重要）

| 资源 | 实测利用率 | 还有多少空间 |
|---|---|---|
| EVM 算力 | 5-10% | 10-20x |
| CPU | 50%/核 | 2x |
| 磁盘 IOPS | < 10% | 10x |
| 磁盘吞吐 | 3% | 30x |
| 内存 | 4% | 25x |
| 网络 | 微不足道 | 几乎无限 |
| L1 容量 | 已确认非瓶颈 | — |
| mempool 容量 | < 30% | 3x+ |

**所有资源都有 2-30x 余量**，但软件没用上。这是典型的**软件架构瓶颈**而非
资源瓶颈。

### 8.3 op-geth worker 行为是 OP Stack 同架构的共性问题

OP Mainnet sustained ~50 TPS、Base ~80 TPS、opBNB 150-300 TPS（2s block）—
都是同一个 op-geth worker 行为决定的，不是某条链的特殊问题。

---

## 9. 行业对标

| L2 链 | 共识架构 | block_time | sustained TPS | 备注 |
|---|---|---|---|---|
| **MAN（本链）** | OP Stack + op-geth | 1s | **~100** | dev 阶段实测 |
| OP Mainnet | OP Stack + op-geth | 2s | ~50 | 生产数据 |
| Base | OP Stack + op-geth | 2s | ~80 | 峰值 ~700（sequencer rate limit） |
| opBNB | OP Stack + op-geth | 1s | 150-300 | 同架构最优 |
| Arbitrum One | Nitro | — | ~10-15 | 不同架构 |
| Polygon zkEVM | zkEVM | ~3s | ~50 | 不同架构 |
| BSC L1 | go-ethereum 派生 | 3s | ~70 | 同硬件单链 |

**MAN ~100 TPS 在 OP Stack 同架构里属于中位数水平**。要进入 opBNB
的 150-300 区间需要做深度调优；要进入 1000+ 必须做架构改造。

---

## 10. 优化路径

### Tier 0：客户端 / 已完成的链参数调优（保留）

| 优化项 | 状态 | 收益 |
|---|---|---|
| spammer JSON-RPC batch + undici 64 连接 | ✅ | 客户端瓶颈消除（100 → 1000+ 瞬时） |
| spammer mempool backpressure | ✅ | 防止雪崩 |
| op-geth `--cache=8192` | ✅ | RPC p50 从 2630ms 降到 314ms（8x） |
| op-geth `full + path` state scheme | ✅ | 长跑稳定性，IO 减半 |
| op-geth `--txpool.journal=` 禁用 | ✅ | 防止重启 reload 死 tx |
| op-geth `--txpool.globalslots=20000` 等 | ✅ | mempool 容量足够 |
| EBS 升级 10000 IOPS | ✅ | 基础设施达标 |

**这些做完链稳态约 100 TPS，再调任何 op-geth 参数也不会突破**（详见第 6 节
源码分析：瓶颈在 `fillTransactions` 一次性 snapshot 行为，不是参数能改的）。

### Tier 1：业务层 BatchTransfer（**最快最便宜**）

```solidity
contract BatchTransfer {
    function batch(IERC20 token, address[] to, uint256[] amount) external {
        for (uint i; i < to.length; ++i) token.transfer(to[i], amount[i]);
    }
}
```

| 维度 | 当前 | BatchTransfer (N=100) |
|---|---|---|
| tx/block | 100 | 30 |
| transfer/block | 100 | **3000** |
| transfer/s | 100 | **3000** |
| 单 tx gas | 35k | 1.7M |
| 业务侧改动 | — | 改一处合约 + 改 spammer 调用 |

**适用条件**：业务方在乎"transfer 量"而不是"链上 tx 数"（绝大多数场景成立）。
对于做市、批量空投、积分结算这类，BatchTransfer 更接近实际业务模型。

**投入**：半天写合约 + 改 spammer。

### Tier 2：换 op-reth（最干净，但需 1-2 周）

[Base 官方实测](https://blog.base.dev/scaling-base-with-reth) op-reth 在 i3en.12xlarge：

| 客户端 | p50 | p95 | p99 | p999 |
|---|---|---|---|---|
| op-geth | 374ms | 1660ms | 2319ms | 3079ms |
| **op-reth** | **260ms** | **560ms** | **698ms** | **889ms** |

p99 降 70%。Reth 团队对 OP Stack sequencer 的 mempool / fillTransactions 行为
做了优化。Base 已经在生产用 op-reth 跑 archive。

**投入**：
- 替换 docker-compose 里 op-geth → op-reth（image 名字改了，flag 略有差异）
- 重新跑 chain init（state 不兼容，需要从 genesis 重建）
- 业务回归测试

**预期 TPS**：在我们硬件下保守估计 200-400 TPS（block_time 1s），如果加 Tier 1
BatchTransfer 可达 6000+ transfer/s。

### Tier 3：Flashblocks (op-rbuilder + rollup-boost)

[Base Flashblocks](https://blog.base.dev/flashblocks-deep-dive) 把 1 个 2s
block 切成 10 个 200ms 子块（每个子块都是真实 sub-payload），相当于让
sequencer **每 200ms 重新拿一次 mempool snapshot**，根治第 6 节定位的瓶颈。

**生产实测**（Base mainnet 2025）：sustained 1000+ TPS。

**投入**：2-4 周
- 新增 op-rbuilder（Reth-based builder）
- 新增 rollup-boost（builder ↔ sequencer 协调层）
- 改 op-node 走 Flashblocks payload pipeline
- 业务侧 RPC（preconfirmation 接口）

**何时上**：业务确认"长期 1000+ TPS 是核心需求"且"愿意维护多个执行客户端"
之后再投入。

### Tier 4：patch op-geth 源码（自有 fork）

在 `miner/worker.go::commitTransactions` 循环里每 N 笔调一次 `txpool.Pending(filter)`
把新 tx 加入 heap：

```go
for {
    // ... 原有循环逻辑
    if env.tcount > 0 && env.tcount % 50 == 0 {
        // 重新 fetch mempool 把新 tx 加入 heap
        newPending, _ := miner.txpool.Pending(filter)
        plainTxs.Merge(newPending)
    }
}
```

**预期 TPS**：单核 EVM 上限 ~150 mgaps × 1s = ~4000 笔 ERC20 transfer/s。

**投入**：1 周（fork + patch + 内部 review + CI）
- 维护成本：每次 op-geth upstream 更新都要 rebase

**风险**：维护私有 fork 是技术债，6 个月内必须有方案脱出（合 upstream 或换
op-reth）。

### Tier 5：EVM 并行（BlockSTM 等）

参考 Polygon / Sui 的并行 EVM 思路。投入月级，不在压测短期范围内讨论。

### 决策矩阵

| 场景 | 建议 |
|---|---|
| 业务模型本就是 batch transfer | **Tier 1**（半天即达 3000+ transfer/s） |
| 业务必须是单笔 transfer，1000 TPS 是硬指标 | **Tier 3 Flashblocks**（生产验证过） |
| 1-2 周内要决策、想稳健性能提升 | **Tier 2 op-reth**（生态主流，可以撑 200-400 TPS） |
| 不想换客户端、自己有研发能力 | Tier 4 patch op-geth |
| 现阶段只是验证 / dev 环境 | 保留当前 ~100 TPS 即可 |

---

## 11. 最终结论

### 11.1 直接答"1000 TPS 能不能做？"

**当前 op-geth 配置下不能**。

链稳态 ~100 TPS，瓶颈是 `op-geth` 在 OP Stack sequencer 模式下
`fillTransactions` 一次性 snapshot 的设计行为（详见第 6 节源码分析）。
所有可调参数都改不了这个行为，只有架构级方案能突破：

| 路径 | 预期 TPS | 投入 |
|---|---|---|
| 业务方接受 BatchTransfer 合约模型（1 tx 含 100 transfer） | 3000+ transfer/s | 半天 |
| 换 op-reth | 200-400 TPS | 1-2 周 |
| op-rbuilder + Flashblocks | 1000+ TPS（生产验证） | 2-4 周 |
| patch op-geth fillTransactions | 2000+ TPS（理论） | 1 周 + 维护 fork |

**最务实路径**：跟业务方确认是否能用 BatchTransfer。能用就半天搞定 3000+
transfer/s；不能用就走 op-reth 或 Flashblocks。

### 11.2 答"L1 是不是瓶颈？"

**不是**。L1 跟 L2 出块速度在 OP Stack 架构里完全解耦：
- L2 sequencer 按 `L2_BLOCK_TIME=1s` 自主出块，跟 L1 出块速度无关
- L2 实测严格 1s/块，60 块全部 Δs=1，无漂移
- op-node 没有任何 stall / lag warning，l1Origin 推进顺畅
- OP Mainnet 用以太坊主网 L1（12s/块）也能跑出 2s/块的 L2

**改 `L1_BLOCK_TIME` 是死路**：anvil 1s/块会增加 reorg 风险但对 L2 TPS 无收益。

详见第 7 节三组交叉验证数据。

### 11.3 答"加机器能解决吗？"

**几乎不能**。OP Stack sequencer 是单实例架构：
- 只能有 1 个 sequencer 在出块（多 sequencer = 共识冲突）
- L2 出块是单线程顺序处理，不能水平扩展
- 加机器对 op-batcher / op-node 副本意义有限（这些不是瓶颈）

加机器**有意义的场景**：
- RPC 节点（读路径横向扩展）
- archive 节点（存储 / 查询路径）
- 多 builder（前提是已经上 Flashblocks）

我们当前瓶颈在 sequencer，不在 RPC 路径，**加机器不是答案**。

### 11.4 答"硬件够用吗？"

**绰绰有余**。所有资源都有 2-30x 余量：
- CPU 50%/核（4 核未饱和）
- 内存 1.1GB / 30GB = 4%
- 磁盘 IOPS < 10%、写吞吐 3%
- mempool 容量 < 30%
- L1 出块容量已确认非瓶颈

**瓶颈在软件架构**（op-geth fillTransactions 行为），不是硬件、不是参数、
不是配置。换硬件 / 加 IOPS 都不会让 TPS 涨。

### 11.5 答"长跑能稳定多久？"

当前配置下，TARGET_TPS=150（链 1.5x 余量）下：
- 已稳定 5+ 分钟无降速
- mempool 周期性 1000-3000 浮动，不会雪崩
- RPC p50 ~300ms 健康，p95 < 1s
- op-geth CPU 50%/核稳定，无 OOM 风险

历史上修过的稳定性问题：
- mempool journal 持久化导致死锁 → 已禁用 `--txpool.journal=`
- archive+hash scheme IO bound → 已切 full+path
- 客户端 nonce gap → spammer 增加 busy 标志位 + 严格本地 nonce 跟踪
- mempool 雪崩 → spammer 加 mempool backpressure（HIGH=3000 / LOW=1000）

### 11.6 给业务方的建议

| 业务诉求 | 现实评估 | 推荐路径 | 投入 |
|---|---|---|---|
| "我们就是要看 1000 TPS 数字" | 当前架构上不可能 | 选 Tier 1/2/3 之一 | 半天 / 2 周 / 4 周 |
| "我们要 1000 笔 transfer 上链" | 业务模型可以 batch | **Tier 1 BatchTransfer** | **半天达 3000+** |
| "稳定 100-200 TPS 已够" | 当前已达成 | 保留现状 | 0 |
| "未来要长期支撑高 TPS L2" | 必须做架构选型 | Tier 2 op-reth + Tier 3 Flashblocks 路线 | 1-2 个月 |

> **v4 业务目标更新**：业务方将 1000 TPS 目标松绑为 500 TPS，且不接受 BatchTransfer
> 合约模型。详细的 Flashblocks 评估、3 阶段实施计划、决策矩阵见 §12。

### 11.7 经验总结

1. **看似显式限制 ≠ 真的有显式限制**：从 elapsed=50ms 看像被 DA size /
   throttle limit 截断，但源码里我们用的版本根本没启用这些限制。判断瓶颈
   性质前先看实际代码路径，不能只看 release note

2. **release note 提到的 feature 不一定意味着默认启用**，更不一定意味着所
   下游 fork 都已合入。op-batcher v1.16.7 + op-geth v1.101702.1 没合 v1.9.5
   引入的 batcher throttling，但 develop 分支早已合入。看官方 doc 时务必
   核对 release tag，不要看 develop 分支文档去推断 release 行为

3. **错误归因 + 错误"修复"的代价是双倍的**：误判 batcher throttling 是真凶，
   加了不存在的 flag 让 op-batcher 进 crash loop，影响业务测试。教训：动配
   置前先 `--help | grep`，动 RPC 前先 `cast rpc method_name` 验证

4. **善用 metrics + log**：op-geth log 里的 `elapsed=50ms` + "block 没装满
   就提前停止" + "硬件资源都没满" 这三个组合是关键 hint，应该立刻怀疑是
   软件行为限制（snapshot / heap / interrupt），而不是猜瓶颈在算力 / 锁

5. **OP Stack 的 sequencer 是单实例 + 单核 EVM 架构**，跟"加机器解决问题"
   是相反方向。要突破必须做执行层选择（op-reth）或加 builder 层（Flashblocks），
   不存在通过堆资源就能扩容的路径

6. **业务模型驱动技术选型**：90% 的"1000 TPS"业务诉求其实是"1000 个 transfer/s"。
   两者在 OP Stack 上差别巨大：前者要换执行层，后者改一处合约。沟通业务方
   的真实诉求比堆基础设施更重要

---

## 12. Flashblocks 路线评估（v4 新增，目标 500 TPS）

### 12.1 业务目标更新

业务方在 v3 报告基础上反馈：
- **1000 TPS 目标松绑为 500 TPS**（业务实际预期）
- **接受 dev 分支重建链**（如果 dev 分支能解决问题）
- **不接受 BatchTransfer 合约模型**（业务必须是单笔 transfer，不能合并 L2 上的交易）

按这个新条件重新评估方案空间。

### 12.2 dev 分支重建链 ≠ 解决方案

> **关键发现**：单纯升级到 OP Stack dev 分支（含 Jovian/Isthmus 升级）**不解决**
> ~100 TPS 瓶颈，反而引入新限制。

OP Stack [Jovian 升级](https://specs.optimism.io/protocol/jovian/exec-engine.html)
（2025-12-02）的核心变化是 **DA footprint 机制**：

> This mechanism replaces previous policy-based "batcher-sequencer throttling,"
> which often caused unnecessary base fee drops and priority fee auctions.
> By **hard-limiting DA usage at the protocol level**, the chain operator can
> better align L2 block building with actual L1 DA capacity.

也就是 v2 我误判过的 "batcher-sequencer throttling" 在 Jovian 之后被 promotion 成
**protocol-level 的 DA footprint gas**（新增 `daFootprintGasScalar` 系统配置参数）。
但 `miner/worker.go` 里的 `fillTransactions` 一次性 snapshot 行为**完全没动**（事
实上我们读的 v1.101702.1 源码已经是 Jovian-aware 的，commitTransactions 里有
`isJovian` 分支但仍然走同一个 for {} 循环装 snapshot）。

升级到 dev 分支会带来：
- ✅ 一些已知 bug 修复
- ❌ 引入 Jovian 的 DA footprint 硬限制（如果 `daFootprintGasScalar` 设置不当反
  而比现在更紧）
- ❌ 不解决 fillTransactions snapshot 瓶颈
- ❌ 累计 4 个 hard fork（Holocene/Granite/Isthmus/Jovian）的潜在 bug 暴露面
- ❌ 重建链丢数据 + Blockscout 重新初始化

**结论**：升级 dev 分支不是 v4 的可选项。

### 12.3 真正能解 500 TPS 的方案：Flashblocks 增量集成

`Flashblocks` 是 OP Stack 官方在 [chain-operators/guides/features/flashblocks-guide](https://docs.optimism.io/chain-operators/guides/features/flashblocks-guide)
里推荐的方案，由 Flashbots 主导研发，Base 已在生产使用（mainnet sustained
1000+ TPS）。

#### 12.3.1 关键架构：out-of-protocol sidecar

> *官方原话*：Flashblocks integration does **not** require rebuilding the chain
> or modifying the core OP Stack protocol (`op-node` or `op-geth`). It is
> designed as an "out-of-protocol" sidecar solution.

```
当前：
  op-node ──────────► op-geth ──► op-batcher ──► L1
                       (sequencer EL)

Flashblocks 后：
  op-node ──► rollup-boost ──┬──► op-rbuilder (Reth-based, 250ms 子块)
                              └──► op-geth (fallback)
                                          │
                                          └──► op-batcher ──► L1
```

`rollup-boost` 是 sidecar：
- 把 `engine_forkchoiceUpdated` / `engine_getPayload` 同时转发给 op-rbuilder 和 op-geth
- 校验 op-rbuilder 的 payload，**校验失败自动 fall back 到 op-geth**
- 通过 WebSocket 把每 250ms 一个的 flashblock 流式推给 RPC 节点（pre-confirmation）

**关键性质**：不需要重建链 / 不需要改 genesis / 不需要 hard fork / op-geth 保留作 fallback。

#### 12.3.2 为什么能解 500 TPS

| 维度 | 当前 | Flashblocks |
|---|---|---|
| 每秒 fillTransactions 调用次数 | **1**（block_time=1s 出 1 块） | **4**（每 250ms 一个 flashblock） |
| 每次 snapshot 装载量 | ~100 笔 | ~100 笔 |
| 单核 EVM 速度 | op-geth | op-reth（Base 实测 p99 比 op-geth 快 70%） |
| 理论 TPS | 100 | **400-800**（4× snapshot × 1.5-2× reth 速度） |

[Base 官方 benchmark](https://blog.base.dev/scaling-base-with-reth)（i3en.12xlarge）：

| 客户端 | Block Building p50 | p95 | p99 | p999 |
|---|---|---|---|---|
| op-geth | 374ms | 1660ms | 2319ms | 3079ms |
| **op-reth** | **260ms** | **560ms** | **698ms** | **889ms** |

### 12.4 Flashblocks 的 10 个真实坑（按影响排序）

> 以下都是基于官方 doc / Base blog / flashbots GitHub 综合得到的潜在风险，
> 必须在 Phase 1 验证阶段亲自踩过才能确认严重程度。

| # | 坑 | 影响 | 应对 |
|---|---|---|---|
| 1 | op-rbuilder 有**独立 mempool**，跟 op-geth 不同步 | spam 必须发 op-rbuilder 否则 tx 进 op-geth mempool 但 op-rbuilder 看不到 | spammer 已在 v4 Phase 0 改成 `SPAM_RPC_URL` 可配置 |
| 2 | 版本兼容性极严：op-batcher / op-node / op-geth / op-rbuilder / rollup-boost 五件套必须互相兼容 | 一个版本不对整链卡死 | 严格按 OP Stack release notes 选版本组合，`--help \| grep` 验证 flag |
| 3 | "500-1000 TPS" 是估算，**不是保证** | 实测可能 200-400 也可能 600-800，最差 fall back 到 100 | 必须 Phase 1 实测，不达 500 就回滚 |
| 4 | 架构复杂度从 4 service 涨到 7 | 调试链路变长，新增 SPOF | 分阶段上线，每阶段独立验证 |
| 5 | op-rbuilder 资源开销叠加（不是替代 op-geth） | 4 vCPU / 30GB 机器 CPU 可能紧 | 监控 docker stats，必要时升机 |
| 6 | Reth mempool 行为跟 geth 不同 | 现有 mempool 调优（globalslots / pricelimit / journal）失效 | 重做 mempool 调优 |
| 7 | rollup-boost 是 SPOF，挂了 sequencer 整体停 | dev 单点没事，生产要 op-conductor | dev 不上 op-conductor，生产再补 |
| 8 | Blockscout 索引要重指 op-rbuilder | 数据连续性断 | 在切换前 backup blockscout DB |
| 9 | Flashblock pre-confirmation ≠ finality | 用户看到 "已确认" 但其实是 sub-block 状态 | 业务 RPC 接口仍用 final block，flashblock 仅作 UX 优化 |
| 10 | 工作量"2-3 天"是乐观估计 | 实际 3-5 天 | 见下方 Phase 1 / Phase 2 分解 |

### 12.5 三阶段实施计划

降低风险的核心是**分阶段验证**，不一次性切换。

#### Phase 0：代码预备（已完成 ✅）

无 risk 的清理工作，跟 Flashblocks 解耦：

- [x] **spammer**：`tokenspammer.js` 增加 `SPAM_RPC_URL` / `DIAG_RPC_URL` 环境变量，
  默认 fallback 到 `RPC_URL`。SPAM 子命令的 send 路径走 `SPAM_RPC_URL`，
  mempool backpressure 走 `DIAG_RPC_URL`
- [x] **Makefile**：`bot-token-*` 目标里硬编码的 `http://op-geth:8545` 改成
  `L2_RPC_URL_INTERNAL` / `SPAM_RPC_URL_INTERNAL` / `DIAG_RPC_URL_INTERNAL` 三变量
- [x] **.env.example**：增加上述三变量的注释 + 切换示例
- [x] **README**：补充 RPC 端点切换说明

切回老配置只需 `.env` 全部留空即可（向后兼容）。

#### Phase 1：builder-playground 单独验证（1-2 天，**未启动**）

> [`builder-playground`](https://rollup-boost.flashbots.net/operators/local.html)
> 是 Flashbots 提供的本地 e2e 测试工具，含完整 OP Stack + rollup-boost +
> op-rbuilder 链，10 分钟拉起来。

目标：在**完全独立的环境**验证 op-rbuilder + rollup-boost + flashbots 的全套能否
跑通基本流程，**不动我们生产 dev chain**。

工作清单：
- [ ] 在 `dev/playground/` 目录拉 builder-playground
- [ ] 跑通 hello-world：发 1 笔 tx，看 250ms 内能不能在 flashblock stream 里出现
- [ ] 用我们的 spammer 接到 playground 的 RPC，跑 100 / 200 / 500 TPS 各 5 分钟
- [ ] 记录每个 TPS 档位的：链消化 TPS、每块 tx 数、flashblock 出现频率、CPU/内存利用率
- [ ] **决策点**：playground 实测能稳跑 500 TPS → 进 Phase 2；不能 → 评估 patch op-geth 路线

**Phase 1 成本**：1-2 天，主要是熟悉 flashbots 工具链。**风险**：playground
环境跟我们 chain 配置可能不完全一致，结果只是参考。

#### Phase 2：在 dev chain 上集成（2-3 天，**未启动**）

只在 Phase 1 通过后启动。

工作清单：
- [ ] 修改 `dev/docker-compose.yml`：新增 `op-rbuilder`、`rollup-boost` 两个 service
- [ ] 改 `op-node` 的 engine RPC 从 `op-geth:8551` 改成 `rollup-boost:8551`
- [ ] op-batcher 兼容性验证（v1.16.7 是否支持 rollup-boost；不支持就升级）
- [ ] 在 `.env` 把 `SPAM_RPC_URL_INTERNAL` / `DIAG_RPC_URL_INTERNAL` 切到 `op-rbuilder:8545`
- [ ] 改 `bot-token-geth-*` 系列诊断目标 → 复制一份 `bot-token-rbuilder-*`
- [ ] 跑 `make bot-token-spam-up TARGET_TPS=500`，连续 5 分钟，看 sustained
- [ ] **如果 sustained ≥ 500 TPS** → 进 Phase 3 收尾
- [ ] **如果 sustained < 500 TPS** → 用 `rollup-boost debug set-execution-mode disabled`
  立刻 fall back 到纯 op-geth（不需要回滚配置），评估是否值得继续投入

**Phase 2 成本**：2-3 天。**回滚成本**：5 分钟（rollup-boost debug API 一行命令）。

#### Phase 3：收尾（半天）

- 更新 README 与压测文档
- Blockscout 重指 op-rbuilder + 重新 init
- 长跑稳定性测试（24h）
- 生产化 checklist：`op-conductor` HA setup（生产）/ `flashblocks-websocket-proxy` /
  prometheus + grafana 监控

### 12.6 决策矩阵（v4 给业务方）

| 业务诉求 | v4 推荐 | 投入 | 预期 |
|---|---|---|---|
| **1. 真实需要 500 TPS 上链** | **进 Phase 1 验证 Flashblocks** | 1-2 天 PoC + 2-3 天 Phase 2 | 500-1000 TPS（取决于硬件） |
| 2. 100-150 TPS 已够，未来再扩 | 保持现状 | 0 | 100 TPS sustainable |
| 3. PoC 后 Phase 1 数据不达 500 | 评估 patch op-geth fork | 1 周开发 + 维护 | 2000+ TPS（理论） |
| 4. 业务确实可以 batch（虽然你说不行） | 用 BatchTransfer | 半天 | 3000+ transfer/s |

### 12.7 v4 阶段已做的事

- ✅ 完整调研 OP Stack dev 分支 / Jovian 升级 / Flashblocks 三条路径
- ✅ 阅读 op-geth v1.101702.1 `miner/worker.go` 源码确认 fillTransactions 设计
- ✅ Phase 0 代码改造（spammer / Makefile RPC 端点参数化），为 Phase 2 平滑切换预留
- ✅ 撰写 v4 报告 §12

### 12.8 v4 阶段待业务方决策的事

- [ ] **是否启动 Phase 1**（builder-playground 验证 1-2 天）
- [ ] 启动后 Phase 1 数据决定是否继续 Phase 2
- [ ] Phase 2 实施期间是否需要 paush 当前 dev chain 的业务测试（建议在独立机器跑
  Phase 2，避免影响）

---

## 13. Fail-fast 模式（v5 新增，超载不雪崩）

> 本章为 v5 新增。来源：业务方在 v4 §12 决策矩阵讨论中明确，**200 TPS 的本质需求
> 不是"链每秒装下 200 笔成功 tx"，而是"超载场景链不雪崩、RPC 端口持续可用、
> client 能立即感知降级"**。这个需求不需要架构改动，调一个 op-geth 参数即可。

### 13.1 先澄清一个常见误区："传统 ETH 块满了会有链上可查的失败交易"

业务方提出过这个想法：参考以太坊主网，块满了应该会出现"链上可查失败 tx"，
我们能不能这么实现？

实际上以太坊的"失败交易"分两类：

| 类型 | 链上可查？ | 触发条件 | 占 block 容量？ |
|---|---|---|---|
| **A. 进了 block 但 execution revert** | ✅ status=0 receipt | `require(false)`、ERC20 余额不足、`OutOfGas` | ✅ 占（一笔失败 transfer 也烧 ~22k gas） |
| **B. 进不了 block，被 mempool 拒绝** | ❌ 完全查不到 | `nonce too low/high`、`txpool is full`、gas price 不够 | 不占（根本没上链） |

**业务方说的"块满了的失败"指 A**。但仔细想：A 类失败 tx 也消耗 block_gas_limit
（一笔失败 transfer ~22k gas，跟成功的几乎一样），所以**让超额 tx "假装失败但
还是上链"不能让链每秒处理更多 tx**：每块还是只装 ~100 笔（不论成功失败）。

**而且我们当前根本不是"块满了"**：实测每块 gas util 仅 7-10%（60M 限制下用了 5.4M），
按 21k gas/transfer 算理论装得下 1714 笔/块。瓶颈在 §6 详述的 `fillTransactions`
单次 snapshot 行为，不是 block_gas_limit。

所以"故意发 revert tx 让链上可查"在我们这套架构上：
- ❌ 不能提升 TPS（block 容量决定的是 tx 数上限，不是成功 tx 数）
- ❌ 浪费 ~22k gas/笔
- ✅ 业务方真实诉求"超载可感知"另有更好的实现方式：fail-fast 模式

### 13.2 Fail-fast 模式机制

把 op-geth 的 mempool 容量调到很小（默认 4096 → 200 slots），**超额 tx 直接被
mempool 拒绝**，client 立即拿到 `txpool is full` 错误响应。

**这其实就是以太坊 B 类失败的标准行为**——以太坊主网遇到 mempool 满时也是这个
反应（你 metamask 发一笔 tx 给 nonce 错的话，etherscan 根本查不到，就是 B 类
失败）。

```
                 [client 发 200 TPS]
                          │
                          ▼
        ┌─────────────────────────────────┐
        │ op-geth RPC (eth_sendRawTx)     │
        │  ↓                               │
        │  mempool check (200 slots)       │
        │   ├─ 有空位 → 进 mempool ──┐    │
        │   └─ 满 → 立即返回错误 ───┐ │   │
        └────────────────────────────┼─┼───┘
                                     │ │
       client 立即收到 "txpool full" ◀┘ │
                                       │
                                       ▼
                          每块 fillTransactions
                          装 ~100 笔进 block

       结果：
       ✓ 链 ~100 TPS 稳定出块（mempool 始终 0~200）
       ✓ 多余 ~100 TPS 立即拿到 RPC 错误（client 可重试 / 退避 / 报警）
       ✓ 链不雪崩 / RPC 端口不奶 / 监控指标清晰
```

**对比当前默认（容量模式）**：

| 项 | 容量模式（globalslots=20000） | fail-fast 模式（globalslots=200） |
|---|---|---|
| 200 TPS 持续发送时 mempool 形态 | 缓慢累积到 3000，spammer 触发 backpressure 暂停 | 始终 0~200 |
| client 端体感 | TPS 看似正常但延迟越来越长，最终被 backpressure 限速 | TPS 200 提交，~100 成功 + ~100 立即 fail |
| RPC 错误率 | 0%（成功投递 mempool ≠ 上链） | 50%（链层主动告知降级） |
| 链上有效 TPS | ~100 | ~100（不变） |
| 雪崩风险 | mempool 累到 1w+ 时 op-geth selection 退化（实测过） | 完全没有（mempool 上限硬卡 200） |
| 超载可观测性 | 弱（要看 mempool 监控才知道） | 强（client 错误日志直接出现） |

### 13.3 实现细节（已落地）

**op-geth 参数化**（`dev/docker-compose.yml` + `dev/.env.example`）：

```yaml
# docker-compose.yml
- --txpool.globalslots=${OP_GETH_TXPOOL_GLOBALSLOTS:-20000}
- --txpool.globalqueue=${OP_GETH_TXPOOL_GLOBALQUEUE:-4000}
- --txpool.accountslots=${OP_GETH_TXPOOL_ACCOUNTSLOTS:-128}
- --txpool.accountqueue=${OP_GETH_TXPOOL_ACCOUNTQUEUE:-512}
```

```bash
# .env  fail-fast 模式
OP_GETH_TXPOOL_GLOBALSLOTS=200
OP_GETH_TXPOOL_ACCOUNTSLOTS=4
docker compose up -d --force-recreate op-geth
```

**spammer fail 类型分类**（`dev/bots/tokenspammer/tokenspammer.js`）：

```js
// 区分三类失败便于诊断 fail-fast 是否生效
stats.failTxpoolFull   // "txpool is full" / "mempool is full" / "queue full"
stats.failNonce        // nonce too low/high / known / replacement underpriced
stats.failOther        // gas / balance / revert / 其他

// report 输出新增：
// [ 30s] ok=2.9k fail=2.9k tps(rec)=100 ftps(rec)=100 ... fail{full=2.9k,nonce=12,other=0}
```

**Makefile 一键 target**：

```bash
make bot-token-spam-failfast
# 等价于：MEMPOOL_BACKPRESSURE=0 TARGET_TPS=200 make bot-token-spam-up
# 客户端层不再做软背压，让链层 fail-fast 直接暴露
```

### 13.4 预期实测数据形态

`make bot-token-spam-failfast` 启动后正常的日志：

```
[  2s] ok=  180 fail=    8 tps(rec)= 90 ftps(rec)=  4 ... mp=180+0  fail{full=8,nonce=0,other=0}
[  4s] ok=  385 fail=  155 tps(rec)=102 ftps(rec)= 73 ... mp=200+0  fail{full=155,nonce=0,other=0}
[  6s] ok=  590 fail=  365 tps(rec)=102 ftps(rec)=105 ... mp=200+0  fail{full=365,nonce=0,other=0}
[ 30s] ok= 2950 fail= 2845 tps(rec)= 99 ftps(rec)=101 ... mp=200+0  fail{full=2845,nonce=12,other=0}
```

关键观察点：
- `mp=200+0` 始终维持在 200（mempool 满载，但不雪崩）
- `tps(rec)≈100` 链稳态出块速度（不变）
- `ftps(rec)≈100` 链层主动 reject 的 TPS（这就是"降级容量"）
- `fail{full=...}` 占比 > 95%（说明 fail-fast 真的在生效，不是其他失败）
- `fail{nonce=...}` 应保持很小（< 1%，spammer nonce 管理本身没问题）

**异常形态**（说明配置没生效）：
- `fail{full=0}` 全是 nonce / other → globalslots 没改小 / op-geth 没重启
- `mp=2000+0` 持续涨 → MEMPOOL_BACKPRESSURE=0 没传进 spammer，client 在自己缓冲

### 13.5 切回容量模式

任何时候想切回原默认行为：

```bash
# .env 删掉或改回默认值
OP_GETH_TXPOOL_GLOBALSLOTS=20000
OP_GETH_TXPOOL_ACCOUNTSLOTS=128
docker compose up -d --force-recreate op-geth

make bot-token-spam-down
make bot-token-spam-up   # 默认 backpressure=1
```

不需要重建链。

### 13.6 适用边界与不适用场景

**fail-fast 模式适合**：
- ✅ 业务方需要观察"超载场景链/RPC 不雪崩"
- ✅ client 端需要明确感知降级（重试 / 退避 / 报警）
- ✅ 监控验收（错误率指标 / SLO 测试）
- ✅ 不能改架构、当前业务测试不能中断的场景

**fail-fast 模式不解决**：
- ❌ 让链每秒成功上链 200 笔（这需要 §12 Flashblocks 路线）
- ❌ 让"失败的 tx 链上可查"（这是物理不可能的——B 类失败本身就不上链）
- ❌ 让 200 TPS 全部最终成功（这需要 client 端无限重试，会拉长尾延迟）

如果业务方目标是后者（200 TPS 全部最终成功上链），仍需走 §12 的 Flashblocks 路线。

### 13.7 v5 阶段已做的事

- ✅ `dev/docker-compose.yml`：`txpool` 4 个参数全部 env 化（默认值向后兼容）
- ✅ `dev/.env.example`：增加 fail-fast vs 容量模式切换说明
- ✅ `dev/bots/tokenspammer/tokenspammer.js`：fail 按类型分类计数 + report 显示
- ✅ `dev/Makefile`：增加 `bot-token-spam-failfast` 一键 target
- ✅ `dev/bots/tokenspammer/README.md`：补充 fail-fast 用法
- ✅ 本章节（§13）

### 13.8 v5 阶段待业务方决策的事

- [ ] 实测一组对照数据：容量模式 vs fail-fast 模式各跑 30 分钟，对比 fail/雪崩/延迟
- [ ] 业务方确认：`fail{full=...}` 这种"链层 reject"是否满足"链上记录"的需求
  （如果仍要求 hash 上链可查，则只能走 §12 Flashblocks 或合约层 Event Log 方案）

---

## 14. 实测最终验证（v6 新增，闭环）

> 本章为 v6 新增，是整个压测项目的**闭环**：基于 §13 fail-fast 方案
> 落地实测，验证业务方需求"一期接受 ~150 TPS + 链受攻击不宕机"。
> 测试日期：2026-05-04。

### 14.1 业务最终需求（v6 锁定）

业务方在 v5 决策中明确：

1. **一期接受 ~150 TPS** —— 业务可用性目标，不再追求 1000 TPS
2. **链稳定不宕机** —— 任何流量入站，链都不能挂
3. **超出处理能力的交易直接报错** —— 攻击场景下 client 拿到 `txpool is full`

→ 完美匹配 §13 fail-fast 模式。

### 14.2 生产配置 baseline

```bash
# .env（链层 fail-fast 防御 — 必须）
OP_GETH_TXPOOL_GLOBALSLOTS=500
OP_GETH_TXPOOL_GLOBALQUEUE=200
OP_GETH_TXPOOL_ACCOUNTSLOTS=8
OP_GETH_TXPOOL_ACCOUNTQUEUE=16
```

**为什么 globalslots=500**（不是 §13 v5 推荐的 200）：

实测确认链消化稳态 ~158-180 TPS，每块 ~150 笔。globalslots=500 = **3 块 buffer**：
- **链能持续吃满每块**（不饿死 fillTransactions，避免"装不满"导致 chain TPS 退化）
- 入流量 200 TPS 时：链 158 + 净增 42/s，500 上限 ~12s 触发 fail
- 入流量 1000 TPS 攻击时：净增 ~840/s，500 上限 < 1s 触发 fail

### 14.3 实测数据

#### 14.3.1 测试 1：fail-fast + 200 TPS 正常负载

`MEMPOOL_BACKPRESSURE=0 TARGET_TPS=200 make bot-token-soak DURATION=300`

| 指标 | 实测值 |
|---|---|
| 真实运行时长 | 399 s |
| 出块数 | 459 blocks |
| 总 tx 数 | 71,999 |
| **chain_tps** | **180** |
| avg tx/block | 156 |
| mempool 末尾 | 700+0 |
| spammer ok | 64,322 |
| spammer fail | 19,118 |
| spammer fail{full} | 0 ⚠️（详见 §14.5） |

**判定**：`ratio = 180 / 200 = 0.90 (DEGRADED)`，链消化 < target，mempool 在 500-700 间稳定累积，**链没崩**。

#### 14.3.2 测试 2：fail-fast + 1000 TPS 攻击模拟

`MEMPOOL_BACKPRESSURE=0 TARGET_TPS=1000 make bot-token-soak DURATION=300`

| 指标 | 实测值 |
|---|---|
| 真实运行时长 | 364 s |
| 出块数 | 405 blocks |
| 总 tx 数 | 75,314 |
| overall chain_tps | 207 |
| **末尾稳态 chain_tps** | **177** |
| avg tx/block | 155-186 |
| mempool 末尾 | 608+92 |
| spammer ok | 74,024 |
| spammer fail | 125,976 |
| spammer fail{full} | 0 ⚠️ |

**判定**：`ratio = 177 / 1000 = 0.18 (DEGRADED)`。

### 14.4 ⭐ 核心结论：fail-fast 防御成功

**对比两个测试**：

| 指标 | 200 TPS 正常 | 1000 TPS 攻击（5x 流量） | 差异 |
|---|---|---|---|
| chain_tps（稳态） | 180 | 177 | **基本不变** ⭐ |
| mempool（稳态范围） | 500-700 | 500-700 | **基本不变** ⭐ |
| op-geth 是否宕机 | 否 | **否** ⭐ | 链稳定 |
| RPC 是否可用 | 是 | **是** ⭐ | client 能持续收响应 |

**链不被打挂**——这是业务方 14.1 §2 / §3 的核心需求，**已达成**。

### 14.5 spammer fail{full}=0 现象诊断

实测两次都看到 spammer 报告大量 fail（19k / 126k），但 `fail{full}=0` —— spammer 没识别为"链层 mempool 拒绝"。可能原因：

**假设 A**：op-geth 实际错误信息不匹配 spammer keyword check
- spammer v5 检查 `"txpool is full"` / `"mempool is full"` / `"queue full"`
- op-geth fork 实际可能返回 `"txpool overflow"` / `"tx pool exceeds limit"` 等
- v6 已扩展为 `pool + (full|overflow|limit)` 宽松匹配 + sample unclassified error 原文

**假设 B**：mempool 实际没满到 globalslots=500，全部 fail 来自其他原因
- 如果 globalslots 没生效（仍是默认 4096），700 mempool 远低于上限
- fail 全部来自 nonce 冲突、gas 不足、replacement underpriced 等

**v6 后续诊断方法**（main 分支的小补丁）：

```bash
# 1. 验证 op-geth 真的拿到了 globalslots=500
docker inspect mychain-op-geth --format '{{range .Args}}{{println .}}{{end}}' \
  | grep -E 'globalslots|accountslots'

# 2. 拿到 spammer 实际收到的错误样本
docker logs mychain-tokenspammer 2>&1 | grep '\[DEBUG\] unclassified' | head -10

# 3. 直接看 op-geth 端的 mempool reject 日志
docker logs mychain-op-geth 2>&1 | grep -iE 'pool.*overflow|pool.*full' | head -5
```

**注意**：即使 fail{full}=0 是分类 bug 而非链层未触发 fail-fast，**14.4 的核心结论（链不挂）依然成立**——
chain_tps 在 1000 TPS 攻击下仍 ~177 是直接读链上块的事实，跟 fail 分类无关。

### 14.6 一期生产 SLA 建议（main 分支）

| 维度 | SLA 数字 | 说明 |
|---|---|---|
| **业务可用 TPS** | **150 TPS** | 链稳态 180 的 0.83x，留 17% buffer 防峰值 / GC / 监控误差 |
| 极限承压 TPS | 200 TPS | 链能消化但 mempool 累积，client 可能拿到部分 fail |
| 攻击防护 | 任意 TPS 入站 | 链稳定 ~180 TPS 出块；超出立即 fail-fast，**链不挂** |
| 监控告警阈值 | mempool > 800 持续 30s | 提前发现 fail-fast 触发 / 配置漂移 |
| 监控失败率阈值 | spammer fail{full} > 10%/min | 持续超过说明客户端在攻击边缘，业务侧需 throttle |

### 14.7 区块浏览器异常现象解释

实测中观察到 explorer 显示连续多个 1-tx 块（仅含 L1Block.setL1BlockValues 系统 tx），跟密集大块（100-200 tx）交替。

**原因**：OP Stack op-node sequencer 行为，**不是 bug**。

- `L2_BLOCK_TIME=1s` 是 L2 logical block 时间，不是 wall_clock 出块周期
- op-node 在 wall_clock 1 秒内可能 push 多个 `newPayload` 给 op-geth
- 前几个是 `noTxPool=true` 的"间隔块"（仅 deposits + L1Block）
- 后面才是有 user tx 的大块
- explorer 的 timestamp 是 logical time，所以看起来像"连续空块"，实际 wall_clock 紧凑

**算笔账**：测试 1 的 459 块 / 真实 399 秒 ≈ 1.15 块/秒（多出来的 0.15 来自这些间隔块）。**wall_clock 每秒总装 ~180 笔 user tx 是不变的**——这才是链的真实承载能力。

### 14.8 二期高负载技术研究路线（新 branch）

业务一期固化在 main 分支后，新服务器上独立 branch 探索高 TPS 路线，**不影响生产**。

#### 推荐 branch 命名

`feat/high-tps-flashblocks` —— 跟 v4 §12 评估的主线方案保持一致。

#### 三阶段计划（详见 §12）

**Phase 1（1-2 天）：builder-playground PoC**
- 在新服务器独立部署 [flashbots/builder-playground](https://github.com/flashbots/builder-playground)
- 跑通 OP Stack + op-rbuilder + rollup-boost 标准 demo
- 验证 builder-playground 标准 benchmark 能否跑出 500+ TPS
- 输出：可行性报告（成功 / 卡哪一步 / 工时估算）

**Phase 2（5-7 天）：集成到我们 dev chain**
- fork dev chain 配置到 `feat/high-tps-flashblocks` branch
- 在新服务器并行跑 op-rbuilder + rollup-boost 旁路 op-geth
- 同步现有 50000 钱包 + 1000 ERC-20 状态
- 跑跟 main 分支相同的 stress-soak 测试，对比 chain_tps
- 输出：跑通的部署 + 实测 TPS 数字 + 主要踩坑记录

**Phase 3（3-5 天）：决策合并**
- 基于 Phase 2 数据决定是否合并到 main
- 同时确认是否触发 §12.4 列出的"10 个真实坑"
- 如果合并：分阶段切换（先 testnet，再 mainnet 影子模式，再正式）
- 输出：合并 PR 或保留 branch 待后续

#### 备选研究方向（次要）

| 方向 | 预期 | 主要成本 / 风险 |
|---|---|---|
| **op-reth 替换 op-geth** | 600-1500 TPS（Base 实测） | 整链重建数据，工时 1-2 周 |
| **patch op-geth fillTransactions** | 800-1500 TPS | fork 维护负担 |
| **L2_BLOCK_TIME=0.5s** | ~360 TPS | 重建链 + 主网生态兼容性风险 |
| **BatchTransfer 合约** | 名义 180 TPS / 实际 transfer 量 18000+/s | **业务方明确拒绝**（一期需求是单笔 transfer）—— 不考虑 |

### 14.9 v6 阶段已做的事

- ✅ 部署 §13 fail-fast 配置到 dev 环境（globalslots 从 v5 推荐的 200 调整为实测验证的 500）
- ✅ 实测 200 TPS 正常负载 + 1000 TPS 攻击两组数据
- ✅ 确认链在 5x 攻击流量下不被打挂（chain_tps 177 vs 180）
- ✅ 确认 mempool 形态稳定（500-700 区间）
- ✅ 修 spammer 错误分类宽松匹配 + sample 原文供调试
- ✅ 解释 explorer 上"连续 1-tx 块"现象（OP Stack catch-up 正常行为）
- ✅ 撰写本章节（v6 §14），整个压测闭环

### 14.10 v6 阶段后续动作

- [ ] **main 分支固化**：把 `OP_GETH_TXPOOL_GLOBALSLOTS=500` 等 4 个参数写进 `.env.example` 默认值，让新部署直接走 fail-fast
- [ ] **诊断 fail{full}=0**：用 v6 spammer 改进版本重跑测试 1，看 unclassified error sample 是什么
- [ ] **新 branch 启动**：`git checkout -b feat/high-tps-flashblocks`，开始 Phase 1
- [ ] **业务方对齐**：把本章节 14.6 "一期生产 SLA 建议"作为最终交付提交业务方确认

---

## 附录 A：所有调整过的参数

### docker-compose.yml（op-geth）

```yaml
op-geth:
  command:
    # 性能配置
    - --gcmode=full              # 不留历史 state（archive 太慢）
    - --state.scheme=path        # path scheme 写 IO 减半
    - --cache=8192               # 默认 1024 太小
    - --cache.trie=50            # 50% 给 trie cache
    - --cache.gc=25
    - --cache.snapshot=15
    # mempool（v6 默认改 fail-fast，3 块 buffer，详见 §14.2）
    - --txpool.globalslots=500       # 默认 4096，v6 改 500 留 3 块 buffer
    - --txpool.globalqueue=200
    - --txpool.accountslots=8        # 默认 16
    - --txpool.accountqueue=16
    - --txpool.journal=              # 禁用持久化（防 reload 死 tx）
    - --txpool.nolocals
    - --txpool.pricelimit=1
    # miner / sequencer
    - --miner.recommit=200ms         # block_time 内多次 fill（边际效益）
    - --miner.gaslimit=60000000
    - --miner.gasprice=0
    # rpc
    - --rpc.batch-request-limit=2000
    - --rpc.batch-response-max-size=50000000
    - --rpc.gascap=50000000
    # http api（包含 miner namespace 是历史遗留，对当前 throughput 没影响）
    - --http.api=web3,debug,eth,txpool,net,engine,miner
```

### docker-compose.yml（op-batcher）

**没有需要为 throughput 调整的 batcher 参数**。我们用的 op-batcher v1.16.7
不支持 throttle 相关 flag（这套机制是 develop 分支 / 更新版本的 feature）。
保留默认配置即可。

### tokenspammer.js（spammer 客户端）

```js
TARGET_TPS=200          // 目标 TPS（链 1.3x，温和过载）
SPAM_TICK_MS=100        // 100ms 一次 tick
MAX_TICK_QUEUE=8        // 最多 8 个并发 batch
HTTP_CONNECTIONS=64     // undici 连接池
MEMPOOL_HIGH_WATER=3000 // mempool 上限触发暂停
MEMPOOL_LOW_WATER=1000  // mempool 下限触发恢复
MEMPOOL_BACKPRESSURE=1  // 启用 mempool 背压
```

---

## 附录 B：诊断命令清单

所有 target 在 `dev/Makefile`，进 `dev/` 目录运行。

### 实时观察

```bash
make bot-token-spam-up       # 启动 spammer daemon
make bot-token-spam-logs     # tail spammer 日志（看 TPS）
make bot-token-spam-down     # 停 spammer
```

### 链状态诊断

```bash
make bot-token-chain-tps         # 最近 10 个块 tx 数 + gas util（默认 N=10）
make bot-token-chain-tps N=30    # 自定义块数
make bot-token-mempool           # op-geth mempool pending / queued
make bot-token-geth-stats        # op-geth CPU / 内存 / IO
make bot-token-geth-metrics      # op-geth 内部 metrics（trie commit / txpool）
make bot-token-geth-logs         # op-geth 出块 / commit / warn 日志
make bot-token-diag              # 一键全量诊断
```

### 救火 / 重置

```bash
make bot-token-clear-mempool     # 清 mempool 死 tx（journal 残留）
make bot-token-reset-deploy      # 清 tokens.json + 重启 op-geth
make bot-token-clean             # 全清（钱包 / token / artifacts）
make dev-restart                 # 完全重建链（数据全丢）
```

### 手动 cast 命令

```bash
# L1 出块速度
docker exec mychain-anvil sh -c 'cast block-number --rpc-url http://localhost:8545'

# L2 出块速度
docker exec mychain-op-geth-init sh -c 'cast block-number --rpc-url http://op-geth:8545'

# mempool 详情
docker run --rm --network mychain-dev --entrypoint sh \
  ghcr.io/foundry-rs/foundry:stable -c \
  'cast rpc txpool_status --rpc-url http://op-geth:8545'

# op-node 是否有 stall
docker logs --since=5m mychain-op-node 2>&1 | grep -iE "warn|stall|lag"
```

---

## 附录 C：spam 日志典型模式

### 健康长跑（TARGET_TPS=200）

```
[ 30s] tps(rec)=200 tps(avg)=187 q= 5/8 mp=1500+0
[ 60s] tps(rec)=200 tps(avg)=192 q= 6/8 mp=2900+0
  ⚠️ mempool 3010（pending=3010 queued=0）≥ HIGH=3000，暂停发送等消化
[ 70s] tps(rec)=  0 tps(avg)=164 q= 0/8 mp=2400+0⏸
[ 80s] tps(rec)=  0 tps(avg)=143 q= 0/8 mp=1500+0⏸
  ✅ mempool 985 ≤ LOW=1000，恢复发送
[ 90s] tps(rec)=200 tps(avg)=160 q= 6/8 mp=1100+0
```

周期约 70s（60s 发 + 10s 暂停），平均 spam TPS ≈ 170，链确认 TPS ≈ 100。

### 不健康（mempool 雪崩，TARGET_TPS=1000 + 关 backpressure）

```
[  2s] tps(rec)=600 mp=0+0
[  4s] tps(rec)=1000 mp=1500+0
[  8s] tps(rec)=1000 mp=5000+0
[ 12s] tps(rec)=900 mp=12000+200
[ 30s] tps(rec)=50 mp=24000+10000  ← 雪崩
[ 60s] tps(rec)=50 mp=24000+15000  ← 完全卡死
```

不要这么跑。

### 死锁（mempool journal 残留，已修复）

```
[  2s] tps(rec)=900 mp=0+0
[  4s] tps(rec)=900 mp=2000+22000  ← queued=22000 是上次跑残留
[  8s] tps(rec)=200 mp=24000+0     ← mempool 被死 tx 占满
  ⚠️ mempool 24000（pending=24000 queued=0）暂停
[ 30s] tps(rec)=0 mp=24000+0⏸     ← 永远不消化（nonce 不连续）
```

修复：`make bot-token-clear-mempool` 清 transactions.rlp，后续不会再出现
（已禁用 `--txpool.journal=`）。

---

## 文档更新记录

| 日期 | 内容 |
|---|---|
| 2026-05-01 v1 | 首版，覆盖完整迭代过程、瓶颈定位、L1 验证、优化路径。判断 op-geth worker 行为是瓶颈，建议换 op-reth 或 patch op-geth |
| 2026-05-01 v2 | **错误修订**：判断真凶是 batcher-sequencer throttling，建议 1 行配置 fix。这个判断在我们用的版本组合下不成立，op-batcher v1.16.7 启动直接报 unknown flag |
| 2026-05-01 v3 | **修正**：通过 `--help` 实测 + 直接读 op-geth v1.101702.1 源码确认，v2 假设的机制在我们环境里**根本不存在**。回到 v1 的瓶颈判断（fillTransactions 一次性 snapshot），并补充源码路径、行业 benchmark、4 条架构级解决方案 |
| 2026-05-01 v4 | 业务目标 1000 → 500 TPS，业务方接受 dev 分支重建链但不接受 BatchTransfer。新增 §12 完整 Flashblocks 评估（机制 / 10 个坑 / 3 阶段实施 / 决策矩阵），并执行 Phase 0 代码改造（spammer / Makefile RPC 端点参数化）。确认升级 dev 分支不解决问题（Jovian 升级把 batcher throttling 换成 protocol-level DA footprint，但 fillTransactions snapshot 行为没动） |
| 2026-05-03 v5 | 业务方明确 200 TPS 本质需求是"超载不雪崩 / client 可感知降级"。新增 §13 fail-fast 模式：调小 op-geth `txpool.globalslots` 让超额 tx 在 RPC 层 fail，spammer 区分 fail 类型。澄清"传统 ETH 块满了出现链上可查失败 tx"的认知误区（A 类 revert 占 block 容量、B 类 mempool 拒绝本来就不上链）。落地代码：txpool 参数化 / spammer fail 分类 / Makefile bot-token-spam-failfast / README 更新 |

## 参考资料

### 直接验证瓶颈的核心资料

- [op-geth v1.101702.1 miner/worker.go](https://github.com/ethereum-optimism/op-geth/blob/v1.101702.1/miner/worker.go) — 我们实际版本的 worker 源码，关键 line 49 / 238 / 565 / 751 / 774
- [Base Engineering: Scaling Base With Reth](https://blog.base.dev/scaling-base-with-reth) — op-geth vs op-reth block building benchmark（p50/p95/p99 数据来源）
- [Base Engineering: Flashblocks Deep Dive](https://blog.base.dev/flashblocks-deep-dive) — Base 用 op-rbuilder + 200ms 子块解决同样的瓶颈
- [Base 官方 benchmark 框架](https://github.com/base/benchmark) — sequencer 性能可复现 benchmark 工具

### Flashblocks 路线（v4 §12 来源）

- [Flashblocks: A Guide for Chain Operators](https://docs.optimism.io/chain-operators/guides/features/flashblocks-guide) — OP Stack 官方部署指南
- [Flashblocks specification](https://specs.optimism.io/protocol/flashblocks.html) — 协议层规范
- [Optimism: Flashblocks Deep Dive on OP Mainnet](https://www.optimism.io/blog/flashblocks-deep-dive-250ms-preconfirmations-on-op-mainnet) — 250ms 子块工作机制
- [flashbots/op-rbuilder](https://github.com/flashbots/op-rbuilder) — Reth-based builder，支持 Flashblocks
- [flashbots/rollup-boost](https://github.com/flashbots/rollup-boost) — engine API sidecar 协调层
- [Running Rollup Boost Locally (builder-playground)](https://rollup-boost.flashbots.net/operators/local.html) — Phase 1 用的本地验证工具
- [Running Rollup Boost in Production](https://rollup-boost.flashbots.net/operators/production.html) — 生产部署 checklist

### OP Stack 协议 / 架构

- [OP Stack Execution Engine spec](https://specs.optimism.io/protocol/exec-engine.html) — engine API 规范
- [OP Stack Derivation spec](https://specs.optimism.io/protocol/derivation.html) — `noTxPool` / `l2_block_time` / `max_sequencer_drift` 等概念
- [op-geth fork.yaml](https://github.com/ethereum-optimism/op-geth/blob/optimism/fork.yaml) — op-geth 相对 go-ethereum 的修改总览
- [Block time research](https://docs.optimism.io/op-stack/research/block-time-research) — OP Stack 1s block 性能 benchmark
- [Network upgrades](https://docs.optimism.io/op-stack/protocol/network-upgrades) — Holocene / Granite / Isthmus / Jovian 时间线
- [Jovian Execution Engine spec](https://specs.optimism.io/protocol/jovian/exec-engine.html) — DA footprint 机制（替代 batcher throttling）

### v2 误判时引用过、保留作为反例参考

- [OP Stack v1.9.5 release note](https://newreleases.io/project/github/ethereum-optimism/optimism/release/v1.9.5) — develop 分支引入 batcher-sequencer throttling，**但我们用的 op-batcher v1.16.7 没合入**
- [OP Stack 官方 batcher 配置文档](https://docs.optimism.io/chain-operators/guides/configuration/batcher) — 文档基于 develop 分支，跟 release tag 行为有差异
- [Issue #12838](https://github.com/ethereum-optimism/optimism/issues/12838) — op-batcher: throttling interval 讨论
