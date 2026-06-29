# MAN 技术方案：Arbitrum Orbit + BSC Parent + Custom Gas Token

> 版本: v1 · 调研日期: 2026-04-22
> 目的: 在"链原生主币 = BSC 上发行的 ERC-20"这一刚性需求下，给出可执行的技术选型与落地路线图。

---

## 0. TL;DR

- **方案**: Arbitrum Orbit **AnyTrust** 模式 + **BSC 作为 parent chain** + **自定义 ERC-20 作为 native gas token**
- **依据**: 这是 2026 年唯一同时满足以下三个条件的栈：
  1. Custom Gas Token 是**官方 GA 功能**（不是 beta、不是 deprecated）
  2. Parent chain 可以是任意 EVM（包括 BSC），由 Arbitrum Foundation 通过 AEP 明确允许
  3. 持续维护、可升级、有大量 production 案例
- **代价**: 需要按 [Arbitrum Expansion Program (AEP)](https://docs.arbitrum.foundation/new-arb-chains) 把 sequencer + MEV 收入的 **10%** 分给 Arbitrum DAO（8% DAO + 2% Protocol Developer Guild）。
- **风险**: 没有公开 production 案例确认"BSC 作 parent + CGT"完整跑通，需要预留 4–6 周做 PoC 验证。

---

## 1. 为什么不是 OP Stack / opBNB（结论性回顾）

| 路径 | 状态 | 是否能满足"主币是 BSC 上 ERC-20" |
|---|---|---|
| opBNB fork | opBNB 不带 CGT 代码 | 否，原生 gas 永远是 BNB |
| OP Stack 主线 + CGT v2 | OP Labs **已弃用**（2024-09 公告），代码已从 monorepo 删除，未来升级不兼容 | 仅在自维护 fork 内可行，长期成本极高 |
| OP Stack op-contracts/v6.0.0 | 最后一个含 CGT 的 tag，部署链路有已知 bug（[issue #13007](https://github.com/ethereum-optimism/optimism/issues/13007)） | 技术上能跑，但是孤儿分支 |
| **Arbitrum Orbit + CGT** | **官方 GA**，[AnyTrust 文档](https://docs.arbitrum.io/launch-arbitrum-chain/configure-your-chain/common/gas/use-a-custom-gas-token-anytrust) / [Rollup 文档](https://docs.arbitrum.io/launch-orbit-chain/how-tos/use-a-custom-gas-token) 持续更新 | **是** |

---

## 2. 架构总览

```
┌────────────────────────────────────────────────────────────────┐
│                BSC Mainnet (Parent / Settlement Layer)           │
│                                                                  │
│   ┌──────────┐   ┌─────────────┐   ┌────────────────────────┐  │
│   │ MyToken  │   │ ERC20Bridge │   │ RollupProxy + Admin/   │  │
│   │ (ERC-20) │   │ (native gas │   │ User Logic             │  │
│   │ 18 dec   │◄─►│  token lock)│   │ (BoLD fraud proofs)    │  │
│   └──────────┘   └─────────────┘   └────────────────────────┘  │
│                                                                  │
│   ┌────────────────┐   ┌───────────────┐   ┌──────────────┐    │
│   │ SequencerInbox │   │ Inbox (delayed│   │ Outbox       │    │
│   │ (batch posts)  │   │  inbox)       │   │ (withdraws)  │    │
│   └────────┬───────┘   └───────────────┘   └──────────────┘    │
└────────────┼─────────────────────────────────────────────────────┘
             │ batches (DACert hash, NOT raw data)
             │
   ┌─────────▼──────────┐         ┌──────────────────────────┐
   │  nitro-node        │ ◄─DAS──►│ Data Availability        │
   │  ┌──────────────┐  │  REST   │ Committee (≥3 members)   │
   │  │ Sequencer    │  │         │ - Member 1 (you)         │
   │  │ Batch Poster │  │         │ - Member 2 (partner)     │
   │  │ Validator    │  │         │ - Member 3 (RaaS / 3rd)  │
   │  │ ArbOS        │  │         └──────────────────────────┘
   │  │ (geth fork)  │  │
   │  └──────────────┘  │
   │   Chain ID: TBD    │
   │   Gas Token: MAN   │
   └─────────┬──────────┘
             │ JSON-RPC :8547
             │
        ┌────▼────┐
        │ Users / │
        │ DApps   │
        └─────────┘
```

**关键差异 vs 原 OP Stack 设计**:
- 节点是**单一 binary** `nitro-node`，sequencer/batch-poster/validator 通过 flag 启用，无需运行 op-geth + op-node + op-batcher + op-proposer 4 个独立进程
- 原生 fraud proofs（**BoLD** 已 GA）— 不像 OP Stack permissioned proposer，Orbit 的 validator 可以是 permissionless（视配置）
- 数据不上 BSC（AnyTrust 模式），只把 DACert 哈希上 BSC，节省 ≥95% 的 parent chain gas

---

## 3. 关键技术约束（必须满足）

### 3.1 MyToken 合约约束（CGT requirements）

[官方限制清单](https://docs.arbitrum.io/launch-arbitrum-chain/configure-your-chain/common/gas/use-a-custom-gas-token-anytrust#requirements-of-the-custom-gas-token):

| 约束 | 当前 `MyToken.sol` 是否满足 |
|---|---|
| 必须是标准 ERC-20 | ✅ |
| **必须 18 decimals** | ✅ |
| 不能有 transfer callback / hook（不能是 ERC-777） | ✅ |
| 不能 rebasing | ✅ |
| 不能有 transfer fee | ✅ |
| `transfer 0` 不能 revert | ✅ |
| `transfer to self` 不能 revert | ⚠️ 当前 `_transfer` 用 `unchecked` 减加，self-transfer 会先减后加同一地址，行为正常但建议加单测覆盖 |
| `name()` `symbol()` 都 ≤ 32 bytes | ✅ ("Matrix AI Network" 13B / "MAN" 3B) |
| 必须部署在 parent chain (BSC) | ✅ Phase 3 已部署到 BSC |
| approve / transfer 必须直接调用 token 合约 | ✅ |

**额外建议**:
- mint 权限部署后立即烧掉（`transferOwnership(0xdEaD)`）或转给 Gnosis Safe
- 总供应量在 constructor 一次性铸足，避免后续 mint 引发的"L2 原生币凭空增加"问题

### 3.2 Parent Chain (BSC) 约束

| 项 | 说明 |
|---|---|
| Chain ID | 56 (mainnet) / 97 (testnet) |
| 区块时间 | 3s |
| 是否支持 EIP-4844 blobs | ❌ 不支持，AnyTrust 模式不依赖 blobs，OK |
| Finality | ~7.5s (2 个 epoch ≈ 15 个区块) |
| 是否有 BoLD 所需的 stake token | 任意 ERC-20 即可，可复用 MAN |

### 3.3 AEP 商业条款

- 收入分成：`sequencer fee + MEV revenue` 的 **10%** 必须可证明地路由给 Arbitrum DAO
  - 8% → Arbitrum DAO Treasury
  - 2% → Arbitrum Protocol Developer Guild
- 实施方式：在 `ArbOwner.setNetworkFeeAccount` / `setL1PricingRewardRecipient` 中配置一个由 chain owner 持有的拆分合约（split contract），定时把 10% 转给 AEP 指定地址
- 不打款：技术上不阻止链运行，但违反 AEP 许可协议，未来纠纷有法律风险

---

## 4. 部署阶段路线图

### Phase 0 — PoC（2 周，必做）
**目标**：在 BSC testnet 上跑通"BSC parent + CGT + AnyTrust"端到端流程，验证可行性。

- [ ] 在 BSC testnet 部署 MyToken
- [ ] 部署 nitro-contracts 的 `RollupCreator` 套件到 BSC testnet
  - 仓库：`OffchainLabs/nitro-contracts`，pin 到最新 stable tag（当前 `v3.1.0` for BoLD）
  - 部署 `BridgeCreator`、`RollupCreator`、`OneStepProverHost`、`ChallengeManager` 等模板
- [ ] 调用 `RollupCreator.createRollup({ nativeToken: MyToken_address, ... })`
- [ ] 部署 1 个 DAS（自己的）+ 联系 Caldera/BCW Group 作为 testnet DAC member
- [ ] 启动 nitro-node（sequencer + batch-poster + validator 一体）
- [ ] 验证 success criteria：
  1. `cast call $RollupAddress 'isERC20Enabled()'` 返回 true
  2. 在 L2 上发送一笔 transfer，gas 用 MAN 支付，余额正确减少
  3. `OptimismPortal` 不存在（Arbitrum 用 `Inbox` / `ERC20Bridge`），通过 `Inbox.depositERC20()` 充值能在 L2 收到原生 MAN
  4. L2 → BSC 提现走 `ArbSys.withdrawEth()` （CGT 模式下其实是提取 native MAN）→ `Outbox.executeTransaction()` 拿回 MAN ERC-20

**Exit criteria**：上述 4 项全部通过 → 进入 Phase 1。任意失败 → 回到方案选择阶段，评估方案 5（独立 PoSA 链）。

### Phase 1 — 团队与商业准备（与 PoC 并行）
- [ ] 与 Arbitrum Foundation 沟通 AEP，明确收入分成实现细节（必要时签 license）
- [ ] 决定 DAC 成员名单（自己 + 至少 2 个第三方，推荐 3-of-5 或 5-of-7）
- [ ] 选定 stake token（推荐 MAN）和 BoLD 参数（challenge period、bond size）
- [ ] 选定 RaaS 合作方（如果不全自营）：Conduit / Caldera / AltLayer / Gelato 都支持 Orbit + CGT；BSC parent 需要先确认其是否提供该组合

### Phase 2 — Mainnet Token 部署
- [ ] 在 BSC 主网部署 `MyToken`
  - 总供应量按经济模型一次性铸足
  - constructor 里直接将 mint 权撤销（删除 `mint` 函数）或 ownership 转 Gnosis Safe
- [ ] 验证 token 合约满足 §3.1 全部约束（必须自动化校验脚本）
- [ ] 在 BscScan 上 verify 合约源码

### Phase 3 — Mainnet L2 合约部署
- [ ] 在 BSC 主网部署 `RollupCreator` 套件（首次会比较贵，约 0.5-1 BNB）
- [ ] 部署 fee token pricer（仅 Rollup 模式需要；AnyTrust 不需要）
- [ ] 调用 `createRollup` 部署 chain 核心合约
  - `nativeToken = MyToken`
  - `chainConfig.chainId = <选定的未占用 chain ID>`
  - `chainConfig.arbitrum.DataAvailabilityCommittee = true` (AnyTrust)
  - `chainConfig.arbitrum.InitialArbOSVersion = 32`（Bianca）或更高
  - `validators[]` = 你的 validator 地址列表
  - `batchPosters[]` = 你的 batch poster 地址列表
- [ ] 部署 `TokenBridgeCreator` 套件并初始化 token bridge（用于桥接其它非 gas token）

### Phase 4 — DAC 与节点部署
- [ ] 每个 DAC 成员部署 DAS（`offchainlabs/nitro-node` 容器，配置 `--data-availability.enable=true`）
  - 硬件：1 vCPU + 1 GiB RAM + S3 存储（archive 模式下需要全历史，~每月 10-100GB 视吞吐）
  - 每个成员生成 BLS keypair（`datool keygen`），把 pubkey 给 chain owner
- [ ] Chain owner 用 `datool` 生成 keyset，调用 `SequencerInbox.setValidKeyset(keyset)`
- [ ] 部署 sequencer node（4 核 + 16 GB + NVMe SSD，约 $600/月）
  - 启动参数：`--node.sequencer=true --node.batch-poster.enable=true --node.staker.enable=true --node.data-availability.enable=true`
  - batch poster 钱包要常备 BNB 用于支付 BSC gas（预算见 §5）
- [ ] 部署 1+ full node 做 RPC 出口（8 核 + 64 GB，约 $800-1500/月）
- [ ] 部署 ≥1 个 active validator + 多个 watchtower validator
  - active validator: $800-900/月，钱包要有 stake token（MAN）
  - watchtower validator: $500/月，无需钱包

### Phase 5 — 上线准备
- [ ] 部署 Blockscout / Routescan 区块浏览器
- [ ] 在 chainlist.org 注册 chain ID + RPC
- [ ] 接入 RPC 提供商（QuickNode / Alchemy / Ankr 已支持自定义 Orbit chain endpoint）
- [ ] 接入 oracle（Chainlink Orbit chain support / RedStone / Pyth）
- [ ] 接入 third-party bridge（LayerZero / Hyperlane / Connext）作为快速通道（canonical bridge 有 7 天挑战期）
- [ ] 部署官方桥前端（参考 `arbitrum/arb-token-bridge-ui` fork）

---

## 5. 成本预算（生产环境，月度）

### 5.1 基础设施
| 组件 | 数量 | 单价/月 | 小计 |
|---|---|---|---|
| Sequencer node (4c/16G/NVMe) | 1 | $600 | $600 |
| Full node (8c/64G/NVMe) | 2 | $1,200 | $2,400 |
| Active validator | 1 | $850 | $850 |
| Watchtower validator | 2 | $500 | $1,000 |
| DAS server (1c/1G/S3) | 1（自己的） | $50 | $50 |
| 区块浏览器 (Blockscout) | 1 | $300 | $300 |
| Grafana + Prometheus | 1 | $150 | $150 |
| **基础设施小计** | | | **$5,350/月** |

### 5.2 Parent Chain (BSC) Gas 成本
- AnyTrust 模式下 batch poster 仅上 DACert 哈希，**~50-100 字节/批次**
- BSC gas price ~3 gwei，每批次约 0.001 BNB
- 假设 24h × 1 批/分钟 = 1440 批/天 ≈ **1.5 BNB/天 ≈ 45 BNB/月**（按实际 TPS 调整）
- 按 BNB $600 计：**~$27,000/月**
- ⚠️ 这是 AnyTrust 模式的乐观估算；如果改 Rollup 模式（calldata 上链）成本会高 5-10 倍

### 5.3 一次性部署成本
| 项 | 估算 |
|---|---|
| BSC 主网部署 RollupCreator 套件 | 1 BNB ≈ $600 |
| 部署 token bridge + 各种 gateway | 0.5 BNB ≈ $300 |
| MyToken 部署 + verify | < 0.1 BNB |
| **一次性总计** | **~$1,000** |

### 5.4 BoLD validator stake
- 默认配置可设为任意 ERC-20，建议 MAN 自有库存
- 每个 active validator 需要锁定 stake（金额由 chain owner 设定）
- 每次 challenge 需要 ~163,109 BSC gas/assertion ≈ < $1

---

## 6. 与 OP Stack 的工程量对比

| 维度 | 旧 opBNB 方案 | Orbit 方案 |
|---|---|---|
| Vendor 仓库 | opBNB + op-geth (2 repos) | nitro + nitro-contracts (2 repos) |
| 节点二进制 | op-geth + op-node + op-batcher + op-proposer (4 个) | nitro-node (1 个) |
| L1 合约部署 | Forge script `Deploy.s.sol`（脚本级别） | `RollupCreator.createRollup()`（一笔交易） |
| Custom gas token | 不可用 | 一等公民支持 |
| Fraud proofs | 部分（Cannon 在迭代） | BoLD 已 GA |
| 升级路径 | 跟随 OP Labs（CGT 已弃用）| 跟随 Offchain Labs（CGT 是 GA 功能） |
| 文档与社区 | opBNB 中文社区好，但 CGT 无支持 | 英文官方文档完善，CGT 有 step-by-step 指南 |

---

## 7. 已知风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| **未找到公开 BSC-parent + CGT production 案例** | 高 | Phase 0 PoC 必做，2 周时间盒，失败则回退方案 5 |
| AEP 10% 收入分成 | 中 | 在经济模型中提前留出空间；与 Arbitrum Foundation 谈判许可细节 |
| BSC reorg 风险（CGT 资产托管在 ERC20Bridge） | 中 | 配置 `delayedSequencer` 等待 BSC finality（~15 区块）才确认 deposit |
| BoLD 在 L2-on-non-Ethereum-L2 的支持 | 中 | nitro-contracts 3.1.0 BoLD 当前主推 L2，需要确认 L2-on-BSC 是否纳入支持矩阵 |
| MAN 价格波动导致 batch poster 收支失衡 | 中 | 实现 fee token pricer；定期自动把 MAN 收入兑换成 BNB 给 batch poster 钱包补血 |
| BSC RPC 公共节点限流 | 低 | 自建 BSC full node 或购买 NodeReal/QuickNode |
| 生产 DAC 成员可信度 | 低 | 至少 5 个成员，3 个由你/合作方自主控制，2 个第三方，2-of-N 攻击成本极高 |

---

## 8. 立即要做的 3 件事

1. **PoC 验证（最重要）**：按 §4 Phase 0 做 BSC testnet 验证，时间盒 2 周
2. **联系 Arbitrum Foundation**：确认 AEP 许可、BSC-parent 是否在他们的支持矩阵
3. **联系 1-2 家 RaaS**：询问 Conduit / Caldera / AltLayer 是否提供"BSC parent + CGT"组合及报价（自建 vs 托管的成本对比）

---

## 9. 替代回退方案（如果 PoC 失败）

如果 Phase 0 验证发现 BSC-parent + CGT 在当前 nitro-contracts 版本下有无法绕过的问题，**唯一退路是方案 5（自建独立 PoSA 链）**：

- fork `bnb-chain/bsc`，改创世
- 创世时预 mint MAN 给桥合约
- 部署 BSC ↔ MAN 锁仓桥（lock-and-mint 模型）
- 21 个 PoSA 验证人由你/合作方持有
- 不再继承 BSC 安全性，但技术成熟

工作量评估：~6-8 周，与 Orbit 路径接近。

---

## 10. 参考资料

- [Arbitrum CGT AnyTrust 配置指南](https://docs.arbitrum.io/launch-arbitrum-chain/configure-your-chain/common/gas/use-a-custom-gas-token-anytrust)
- [Arbitrum CGT Rollup 配置指南](https://docs.arbitrum.io/launch-orbit-chain/how-tos/use-a-custom-gas-token)
- [AnyTrust Protocol 内部原理](https://docs.arbitrum.io/inside-anytrust)
- [DAC 部署指南](https://docs.arbitrum.io/launch-arbitrum-chain/configure-your-chain/common/data-availability/data-availability-committees/get-started)
- [Arbitrum Expansion Program 官方说明](https://docs.arbitrum.foundation/new-arb-chains)
- [nitro-contracts 仓库](https://github.com/OffchainLabs/nitro-contracts)
- [orbit-actions 升级脚本](https://github.com/OffchainLabs/orbit-actions)
- [createERC20Rollup 部署脚本](https://github.com/OffchainLabs/nitro-contracts/blob/main/scripts/createERC20Rollup.ts)
- Production 案例：[ApeChain](https://docs.apechain.com/architecture)、[Xai](https://docs.xai.games)、[Degen Chain](https://www.degen.tips)
