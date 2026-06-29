# MAN 技术方案全景对比 — "BSC 上代币作为本链原生 Gas"

> 版本: v3 · 调研日期: 2026-04-22（二次复核）
> 配套文档: `PLAN_ORBIT_BSC.md` (Arbitrum Orbit 详细方案)
> 本文目的: 在调研了 Avalanche L1 / Cosmos EVM / L3 / OFT / OP Stack CGT v2 之后，给出**完整的方案全景**与**决策矩阵**。
> v3 修订要点: 修正 v2 对 OP Stack CGT v2 的误判（v2 不是被弃用，而是 2026-02-09 随 Upgrade 18 主网 GA），并按"必须 Ethereum L2 + 自定义 native gas + 不付商业费 + 节点尽量少"4 条硬约束重新排序。

---

## 0. 重大调研更新

> 本节是 v3 更新（2026-04-22 二次复核）。前一版本的两个核心判断都需要修正：
>
> 1. **OP Stack CGT v2 不是被弃用，而是 2026-02-09 随 Upgrade 18 主网 GA**。前一版本把 legacy CGT v1 的弃用错挂在 v2 头上，结论反过来了。
> 2. **甲方需求最终被锁死成 4 条硬约束**：必须 Ethereum L2 + 自己 token 做 gas + 不付商业费用 + 节点尽可能少。在这组约束下，Avalanche L1（独立 L1）和 Arbitrum Orbit（带 AEP 10%）都被排除。

### 关于 CGT v2 现状的事实清单

| 维度 | 事实 | 来源 |
|---|---|---|
| 治理状态 | Upgrade 18 — Custom Gas Token v2 and Kona Proofs，2026-02-03 通过，2026-02-09 主网激活 | [vote.optimism.io U18 提案](https://vote.optimism.io/proposals/77621298185123846119233191553645120427678039792258174752758738057653049982021) |
| 合约版本 | `op-contracts/v6.0.0` 包含 CGT v2 实现 | [docs.optimism.io CGT 概览](https://docs.optimism.io/op-stack/features/custom-gas-token) |
| 部署工具 | `op-deployer v0.6.0` 通过 `--intent-type custom` + `[chains.customGasToken]` 配置块支持 | [docs.optimism.io 部署指南](https://docs.optimism.io/chain-operators/guides/features/custom-gas-token-guide) |
| 架构变化 | 不再"L1 锁 ERC-20 → L2 mint"。L2 创世直接铸出独立 native asset；L1↔L2 桥**移到应用层**，由 `LiquidityController.authorizeMinter()` 授权后 mint/burn | 同上 |
| 新 predeploy | `NativeAssetLiquidity`、`LiquidityController` | 同上 |
| ETH 处理 | `isCustomGasToken=true` 时 OptimismPortal/Bridge/Messenger 拒绝 `msg.value`，ETH 通过 L1-WETH 当 ERC-20 桥进 | 同上 |
| 限制 | 当前**只支持 18-decimal token**；与 legacy CGT v1 无迁移路径 | 同上 |
| Production 案例 | 截至 2026-04（U18 上线 2.5 个月）**没有公开命名的 production CGT v2 链**，团队会是首批吃螃蟹之一 | WebSearch（无结果） |
| 之前误判的来源 | GitHub issue #13327（2025-02 关闭）说"code removed"指 legacy CGT v1，关闭原因是要重做 v2；Conduit/Alchemy 2024-2025 年文章描述 v1 弃用，已过时 | [#13327](https://github.com/ethereum-optimism/optimism/issues/13327) |

### 重新排序的结论

前两版按"成熟度 + 商业自由度"把 Avalanche L1 推到 P0。**在追加"必须 Ethereum L2"之后**：
- Avalanche L1（独立 L1）→ 不满足"L2"硬约束
- Arbitrum Orbit（Ethereum parent，但 AEP 10%）→ 不满足"不付商业费用"
- **OP Stack v6.0.0 + CGT v2** → 4 条硬约束**全部满足**，但要承担"首批生产用户"风险

下面表格已重排，OP Stack v6.0.0 + CGT v2 升为 P0；其他方案保留作对照。

---

## 1. 方案全景（共 8 条路径）

按 4 条硬约束（**Ethereum L2 + 自定义 native gas + 无商业费 + 节点尽量少**）打分后的排序：

| # | 方案 | 是否 L2 | "主币 = BSC 上代币"实现方式 | 商业费 | 节点轻 | 成熟度 | 4 硬约束满足 | 推荐度 |
|---|---|---|---|---|---|---|---|---|
| 1 | **OP Stack v6.0.0 + CGT v2（官方主线）** | ✅ 是（Ethereum L2） | L2 创世预 mint native；BSC↔L2 应用层桥经 `LiquidityController.mint/burn` 维持 1:1 | ✅ 无 | ✅ sequencer+batcher+proposer | ⭐⭐⭐ U18 主网刚 GA（2026-02-09），无公开 production 案例 | **4/4** | **P0**（唯一同时满足 4 条） |
| 2 | **Avalanche L1 + Native Minter + 桥** | ❌ 独立 L1 | BSC ERC-20 → LayerZero/Wormhole 桥到 L1 → Native Minter mint | ✅ 无 | ✅ ≥1 validator | ⭐⭐⭐⭐⭐ 80+ production | **3/4**（不是 L2） | P1（如能放弃 L2 硬约束，技术上最稳） |
| 3 | **Arbitrum Orbit + CGT + Ethereum parent** | ✅ 是（L2） | RollupCreator(nativeToken=MyToken on L1) | ❌ AEP 10% | ✅ 单 nitro-node | ⭐⭐⭐⭐ GA | **3/4**（要付费） | P1（如能松动"不付费"约束，最快上线） |
| 4 | **ZK Stack (Matter Labs) + Custom Base Token** | ✅ 是（zkRollup） | L1 锁 ERC-20 → L2 mint 为 native | ✅ 无 | ⚠️ +prover（可外包） | ⭐⭐⭐ GA 但 BSC token 需先桥到 ETH | **3.5/4**（prover 复杂） | P2（OP Stack 走不通时的 zk 备选） |
| 5 | **Polygon CDK + 自定义 native + Ethereum parent** | ✅ 是（zkRollup/Validium） | 类似 ZK Stack | ✅ 无 | ⚠️ +prover | ⭐⭐⭐ 文档完整度不及 ZK Stack | **3.5/4** | P2 |
| 6 | **Arbitrum Orbit + CGT + Arb One parent**（L3） | ✅ 是（L3） | LayerZero OFT 把 MAN 桥到 Arb One，再作为 L3 native | ❌ AEP 10% | ✅ 单 nitro-node | ⭐⭐⭐⭐ GA | 3/4 | P3 |
| 7 | **Cosmos EVM (前 evmOS)** | ❌ 独立 L1 | BSC → Axelar GMP → bank module mint denom | ✅ 无 | ❌ 自营 PoS 验证人集合 | ⭐⭐⭐⭐ Ondo/Mezo/Mantra 等在用 | 2/4 | P3 |
| 8 | **bsc/go-ethereum fork PoSA + 自建桥** | ❌ 独立 PoSA | 创世预 mint 给桥合约 + lock-mint 桥 | ✅ 无 | ❌ 21+ 验证人 | ⭐⭐⭐⭐ 技术成熟，运维最重 | 2/4 | 不推荐 |

> **关于 OP Stack 与 CGT 的澄清**（避免混淆）：
> - **opBNB fork**（`bnb-chain/opbnb`，前一版部署脚本依赖）：**从未合入** CGT，无论 v1 还是 v2。如果要走 OP Stack + CGT，**必须切到 Optimism 主线**而不是 opBNB 分支。
> - **Optimism 主线 Legacy CGT v1**：曾经以 `op-contracts/v2.0.0-beta.2` 出现过，2024-05 后逐步弃用、代码 2025-02 移除。
> - **Optimism 主线 CGT v2**：架构完全重做（独立 native asset + 应用层桥 + `NativeAssetLiquidity`/`LiquidityController` 两个 predeploy），合并进 `op-contracts/v6.0.0`，**2026-02-09 随 Upgrade 18 主网激活**，目前是 OP Labs 主线维护、未来 hardfork 兼容路径明确的特性。
> - **结论**：v2 是当前唯一同时满足"Ethereum L2 + 自定义 native gas + 无商业费"的官方维护方案；最大风险不是技术死链，而是**首批生产用户的未知问题**——上线才 2 个月，没找到公开命名的 production 案例。

---

## 2. P0 方案：Avalanche L1（详细技术方案）

### 2.1 为什么这是最优解

| 对比维度 | Avalanche L1 | Arbitrum Orbit |
|---|---|---|
| 技术成熟度 | 2022 已 GA，3.5 年 | 2024-01 GA，2 年 |
| Production CGT 链数 | 80+ | 不到 20（公开） |
| 商业条款 | 无 revenue share | AEP 10% sequencer/MEV 给 Arb DAO |
| 自定义 gas token 实现 | 链原生（Native Minter precompile） | 需要 ERC20Bridge + native bridging |
| 节点二进制 | 单一 `avalanchego` + `subnet-evm` plugin | 单一 `nitro-node` |
| L1 部署成本 (Etna 之后) | ~$50/月 P-Chain fee | ~$1k 一次性 + parent gas |
| BSC 直接作 parent | N/A（不是 L2） | 未公开 production 案例 |
| 跨链桥到 BSC | LayerZero / Wormhole / Axelar / Stargate / Avalanche ICTT | LayerZero / Wormhole / Hyperlane / 自建 |
| Validator 数量 | 自定 (≥1，推荐 ≥5) | 自定 |
| Stake token | 任意 ERC-20 | 任意 ERC-20 |
| 安全继承 | Avalanche P-Chain 主网验证人 | BSC（如果 BSC parent）/ Ethereum（如果 L3） |

**关键权衡**: Avalanche L1 不"继承 BSC 安全性"，但继承 Avalanche P-Chain 的 PoS 安全（834 active validators，Q3 2025）。如果你的需求只是"主币是 BSC 上的代币"而不严格要求"L2 必须 settle 到 BSC"，Avalanche L1 是显著更优解。

### 2.2 技术架构

```
┌──────────────────────────────────────────────────────────────┐
│              BSC Mainnet (Token Origin)                       │
│                                                                │
│  ┌──────────────┐         ┌────────────────────────────────┐ │
│  │   MyToken    │◄───────►│  Bridge Adapter                │ │
│  │   (ERC-20)   │  lock   │  (LayerZero MintBurnOFTAdapter │ │
│  │              │   /     │   或 Wormhole NTT 或自建)      │ │
│  │              │  unlock │                                │ │
│  └──────────────┘         └────────────────┬───────────────┘ │
└────────────────────────────────────────────┼─────────────────┘
                                             │
                              cross-chain message
                                             │
┌────────────────────────────────────────────▼─────────────────┐
│         MAN L1 (Avalanche L1 / subnet-evm)                │
│         Chain ID: 自选；Block time: 2s（可调到 1s）            │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Genesis-enabled Precompiles:                            │ │
│  │  - 0x..0001 NativeMinter   ← bridge adapter 是 admin    │ │
│  │  - 0x..0002 TxAllowList    (可选，用于合规)             │ │
│  │  - 0x..0003 FeeManager     ← 动态调 gas 参数            │ │
│  │  - 0x..0004 ContractDeployerAllowList (可选)            │ │
│  │  - 0x..0005 RewardManager  ← 配置 fee 去向               │ │
│  │  - WarpMessenger (ICTT)    ← Avalanche 内部跨链         │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                                │
│  Native gas token: MAN (mintable via NativeMinter)            │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Bridge Receiver Contract (作为 NativeMinter admin)      │ │
│  │  - 收到 LayerZero/Wormhole 消息                         │ │
│  │  - 调用 NativeMinter.mintNativeCoin(to, amount)        │ │
│  │  - 反向：用户 burn 原生币 → 触发跨链消息 → BSC 解锁     │ │
│  └────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
                         │
              ┌──────────┼──────────┐
              │          │          │
        ┌─────▼───┐ ┌────▼────┐ ┌──▼──────────┐
        │Validator│ │Validator│ │ Full Node   │
        │   #1    │ │   #2-N  │ │ (RPC)       │
        └─────────┘ └─────────┘ └─────────────┘
        Validators 自动从 P-Chain 同步验证人集
```

### 2.3 核心组件清单

#### 2.3.1 链端（subnet-evm 配置）
- 在 genesis.json 里启用 4 个核心 precompile：
  - `contractNativeMinterConfig` — 让指定地址（bridge contract）能 mint 原生币
  - `feeManagerConfig` — 动态调整 base fee / gas limit
  - `feeConfig`（非 precompile）— 初始 gas 参数
  - `allowFeeRecipients: false` — 默认烧掉 fee（也可改为发给 sequencer）
- `subnet-evm` 仓库：[`ava-labs/subnet-evm`](https://github.com/ava-labs/subnet-evm)，截至 2026-04 最新 stable 版本支持 ACP-176 / ACP-224 动态 gas 算法

#### 2.3.2 跨链桥（关键决策点）

三种实现，按推荐度：

| 方案 | 实现 | 优点 | 缺点 |
|---|---|---|---|
| **A. LayerZero OFT (MintBurnOFTAdapter)** | BSC 端用 `OFTAdapter` lock 原 ERC-20，Avalanche L1 端用 `MintBurnOFTAdapter` + bridge contract 作为 `NativeMinter` admin | LayerZero 是 OFT 标准，Avalanche L1 已支持 `EndpointV2Alt`（专门为非 ETH gas 设计），运维最轻 | 信任 LayerZero DVN 安全模型 |
| **B. Wormhole NTT (Native Token Transfers)** | BSC 端 lock，Avalanche 端 mint，使用 Wormhole guardian network | 多链生态广，支持 25+ chains | NTT 是 2024 才 GA 的新协议，相对 OFT 案例少 |
| **C. 自建 lock-mint 桥** | 仿照 [Avalanche 官方 2022 教程](https://docs.avax.network/deprecated/tutorials-contest/2022/erc20-as-subnet-gas-token)，自己写桥合约 + relayer | 完全自主可控 | relayer 单点故障，需要自己运维监控 |

**推荐 A (LayerZero OFT)**：成熟、标准、tooling 完整。

#### 2.3.3 桥合约骨架（BSC 端 + Avalanche L1 端）

**BSC 端** - lock 原 ERC-20，发送 OFT 消息：
```solidity
// BSC 上：使用 OFTAdapter（不是 MintBurnOFTAdapter，因为 MyToken 在 BSC 上不允许桥 burn）
contract MyTokenOFTAdapter is OFTAdapter {
    constructor(address _token, address _lzEndpoint, address _owner)
        OFTAdapter(_token, _lzEndpoint, _owner) Ownable(_owner) {}
}
```

**Avalanche L1 端** - 收到消息后调用 NativeMinter mint 原生币：
```solidity
// Avalanche L1 上：自定义 OApp 直接 mint 原生币
import "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

interface INativeMinter {
    function mintNativeCoin(address addr, uint256 amount) external;
}

contract MANNativeBridgeReceiver is OApp {
    INativeMinter constant NATIVE_MINTER =
        INativeMinter(0x0200000000000000000000000000000000000001);

    constructor(address _endpoint, address _owner)
        OApp(_endpoint, _owner) Ownable(_owner) {}

    function _lzReceive(
        Origin calldata _origin,
        bytes32 /*_guid*/,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override {
        (address to, uint256 amount) = abi.decode(_message, (address, uint256));
        // 收到消息时已经验证来源 chainId 是 BSC，且来自我们的 OFTAdapter
        NATIVE_MINTER.mintNativeCoin(to, amount);
    }

    // 反向：用户存入原生币，发起跨链解锁
    function withdrawToBSC(uint32 _dstEid, bytes32 _to, uint256 _amount, bytes calldata _options)
        external payable
    {
        // 1. 接收 _amount 的原生币（msg.value 必须 == _amount + fee）
        // 2. burn 原生币（直接 transfer 到 0xdead，因为 NativeMinter 没有 burn 接口）
        require(msg.value >= _amount, "insufficient value");
        payable(address(0xdEaD)).transfer(_amount);

        // 3. 发送 LayerZero 消息回 BSC，由 BSC 端 OFTAdapter 解锁 ERC-20
        bytes memory payload = abi.encode(_to, _amount);
        _lzSend(_dstEid, payload, _options, MessagingFee(msg.value - _amount, 0), payable(msg.sender));
    }
}
```

**关键安全点**：
- `MANNativeBridgeReceiver` 必须在 genesis 时被设为 `NativeMinter` 的 admin（唯一 minter）
- `OApp.peers` 必须只允许来自 BSC 的特定 OFTAdapter 地址，杜绝任何其他 chain/contract 假冒
- BSC 端的 `OFTAdapter` lock 的 ERC-20 数量必须严格等于 Avalanche L1 上流通的原生币总量
- 部署后用 `setEnforcedOptions` 锁死 gas 参数，避免重入攻击

### 2.4 已知 Production 案例（详细）

| 项目 | 原生币 | 来源 | 用例 | 上线时间 |
|---|---|---|---|---|
| **DeFi Kingdoms** | JEWEL → CRYSTAL | 自有 Subnet | Web3 游戏 | 2022 Q3 |
| **Dexalot** | ALOT | 自有 Subnet | 中心化撮合 + 链上结算 DEX | 2023 Q1 |
| **Beam** | BEAM | 自有 Subnet（前身 MC2） | 游戏 hub，Merit Circle 旗下 | 2023 Q4 |
| **GUN by Off The Grid** | GUN | 自有 Subnet | AAA 级 BR 游戏 | 2024 Q4 |
| **Lamina1** | L1 | 自有 Subnet | Neal Stephenson 的元宇宙基础设施 | 2024 |
| **Pulsar** | PSR | 自有 Subnet | DeFi | 2024 |
| **DOS** | DOS | 自有 Subnet | 类 SocialFi | 2025 |
| **Henesys (Maple Story Universe)** | NXPC | 自有 Subnet | Nexon 旗下 MapleStory 链游 | 2024 Q4 |

**关键事实**：所有这些案例都是把"自定义 ERC-20 / 自创 token 作为 native gas"，**没有公开案例**展示"先在 BSC 发币，再桥到 Avalanche L1 作 native gas"。但是技术架构上完全相同，区别仅在 token 来源（自创 vs 来自 BSC）。

### 2.5 部署阶段路线图（Avalanche L1 路径）

#### Phase 0 — PoC（1.5 周，比 Orbit 短）
- [ ] 在 Fuji testnet 部署 MyToken（如果还没部署）
- [ ] 用 [Avalanche-CLI](https://github.com/ava-labs/avalanche-cli) 一条命令创建测试 Subnet：
  ```bash
  avalanche subnet create man --evm
  avalanche subnet deploy man --fuji
  ```
- [ ] genesis.json 启用 NativeMinter precompile
- [ ] 部署 LayerZero OFTAdapter（BSC testnet）+ MANNativeBridgeReceiver（MAN testnet）
- [ ] 设置 LayerZero peers，从 BSC 锁 100 MAN，验证 MAN testnet 上对应账户原生余额增加
- [ ] 验证反向流程：burn 原生币 → BSC 解锁

**Exit criteria**：双向桥成功，gas 用 MAN 支付。

#### Phase 1 — 经济模型与商业准备（与 PoC 并行）
- [ ] 决定 validator 数量与质押要求
- [ ] 决定 fee 去向：burn / 给 validator / 给 sequencer fee vault
- [ ] 评估 LayerZero DVN 配置（默认 + 自定义 DVN 提高安全性）
- [ ] 准备 P-Chain 操作账户（部署 L1 仍需 ~10 AVAX）

#### Phase 2 — Mainnet Token + Bridge
- [ ] BSC 主网部署 MyToken（如果还没）
- [ ] BSC 主网部署 OFTAdapter
- [ ] BSC 主网部署 LayerZero DVN 配置

#### Phase 3 — Mainnet L1 部署
- [ ] 在 Avalanche 主网用 `avalanche-cli` 或 `avalanchego` 直接部署 L1
- [ ] genesis.json 配置：
  - chain ID（chainlist.org 查未占用号段）
  - NativeMinter admin = MANNativeBridgeReceiver 地址
  - 18 decimals 原生币
  - 初始分配 = 0（所有币必须从 BSC 桥来，避免膨胀）
  - feeConfig.minBaseFee 根据 MAN/USD 价格设置
- [ ] 部署 MANNativeBridgeReceiver
- [ ] 设置 LayerZero peers（BSC ↔ MAN）
- [ ] 在 P-Chain 注册 L1 + 验证人

#### Phase 4 — 验证人与节点
- [ ] 部署 ≥5 个 validator（推荐 7-21 个）
  - 硬件：8 核 / 16 GB / 1 TB NVMe（Avalanche 推荐配置）
  - 每个 validator 需要质押（默认 AVAX 或自定义 token）
- [ ] 部署 ≥2 个 RPC full node
- [ ] 部署 Subnets-EVM Indexer + Blockscout

#### Phase 5 — 上线
- [ ] 注册 chainlist.org
- [ ] 上 Core 钱包、MetaMask 默认列表
- [ ] 上 Avalanche bridge UI 或自建桥前端

### 2.6 成本预算（Avalanche L1）

| 项 | 数量 | 单价/月 | 小计 |
|---|---|---|---|
| Validator (8c/16G/1TB) | 5-21 | $300-500 | $1.5k-10k |
| Full node (RPC, 8c/32G/2TB) | 2 | $600 | $1.2k |
| 监控 + 浏览器 | 1 | $400 | $400 |
| Etna L1 fee（动态） | - | ~$50-200 | $50-200 |
| LayerZero relayer fee（按交易量） | - | ~按消息计费 | 用户出 |
| **合计** | | | **~$3k-12k/月** |

对比 Orbit 方案的 $32k+/月（基础设施 + BSC gas），Avalanche L1 月成本至少**便宜 60-90%**。

### 2.7 风险清单

| 风险 | 等级 | 对策 |
|---|---|---|
| LayerZero 桥被攻击/审查 | 中 | 配置自定义 DVN（比如 自己 + Google Cloud + Polyhedra），rate limit |
| Validator 串谋（< 5 时） | 中 | 至少 5 validator，分布在不同地理/法人 |
| MAN 在 Avalanche L1 上膨胀（bridge bug） | 高 | NativeMinter admin 严格只是 bridge 合约，bridge 合约用多签控制升级 |
| Avalanche P-Chain 整体攻击 | 低 | 继承主网安全 |
| 不能 settle 回 BSC（不是 L2） | 低 | 业务上接受"独立 L1 + 桥"语义即可，与 Polygon PoS / Base 等同模式 |

---

## 3. P1 备选方案：Arbitrum Orbit L3 on Arb One

如果"L2 安全继承"是关键诉求，但担心"BSC 作 parent"未验证的风险，可以选 L3：

```
┌────────────┐  LayerZero  ┌──────────────┐  Orbit  ┌─────────────┐
│ BSC        │   OFT       │ Arbitrum One │ native  │ MAN L3  │
│ MyToken    │────────────►│ MyToken      │────────►│ Native: MAN │
│ (ERC-20)   │   (lock-    │ (xMAN OFT)   │  CGT    │             │
│            │   mint)     │              │  bridged│             │
└────────────┘             └──────────────┘         └─────────────┘
              security: BSC + LayerZero    security: Arb One + Ethereum
```

**优点**：
- Arb One 是 Orbit 已验证 parent
- 继承 Ethereum 安全性
- 不需要在 BSC 部署 RollupCreator 套件

**缺点**：
- 用户 deposit 路径长：BSC → Arb One → MAN L3（需要两步）
- 跨链费用累加
- "代币起源在 BSC" 在用户感知上变弱

---

## 4. P2 备选方案：Cosmos EVM (前 evmOS)

### 4.1 为什么也值得考虑
- 完全 sovereign，没有任何上层 dependency
- IBC 生态原生，与 Cosmos 100+ 链互通
- Cosmos SDK 模块化，业务定制空间最大（自定义 staking 模型、governance、vesting）
- 已被 **Ondo, Mezo, Mantra, XRP sidechain, Telegram TAC, Stable** 等使用

### 4.2 实现路径
1. 用 [`cosmos/evm`](https://github.com/cosmos/evm) 启动一条 CometBFT + EVM 链
2. 配置 `coin_type=60` + `EthSecp256k1` keys（兼容 MetaMask）
3. 配置 18 decimals gas denom（推荐，避免 `x/precisebank` 复杂度）
4. 通过 [Axelar GMP](https://docs.axelar.dev/dev/general-message-passing/cosmos-gmp) 与 BSC 互通
5. 桥合约用 `x/erc20` 模块自动把 IBC token 表示为 ERC-20，但 gas 用 bank module 的 native denom

### 4.3 与 Avalanche L1 的对比

| 维度 | Cosmos EVM | Avalanche L1 |
|---|---|---|
| 安全模型 | 自有 PoS 验证人 | 自有 PoS + Avalanche P-Chain 协议层 |
| EVM 兼容性 | 完整（包括 EIP-1559/2930/7702） | 完整 |
| 跨链 | IBC + Axelar GMP | LayerZero / Wormhole / Avalanche ICTT |
| 工具链成熟度 | Cosmos 生态（中等） | Avalanche + EVM（高） |
| Validator 启动门槛 | 完全自营，需要自己组验证人 | 加入 Avalanche P-Chain 验证人池 |
| 节点同步速度 | CometBFT 即时 finality | Snowman 共识 ~1s finality |

如果你团队懂 Cosmos SDK 或者已经有 Cosmos 链运营经验，这是非常好的选择。否则学习曲线陡。

---

## 5. P3 备选方案：独立 PoSA + LayerZero OFT（最简单兜底）

如果 Avalanche L1 / Cosmos EVM 都觉得复杂，最朴素的方案：

1. fork [`bnb-chain/bsc`](https://github.com/bnb-chain/bsc) 或 [`go-ethereum`](https://github.com/ethereum/go-ethereum) Clique
2. 创世时**预 mint 全部 MAN 总量到 bridge 合约地址**
3. bridge 合约接收 LayerZero 消息后，从自己余额 transfer 给用户
4. 反向：用户转回 bridge 合约 → 触发 LZ 消息 → BSC 解锁

**优点**：
- 技术栈最熟悉（go-ethereum）
- 无需 L1/L2 基础设施
- 可以自己控制全部验证人

**缺点**：
- 完全独立 PoSA，需要自己维护 21 个验证人
- 没有 Native Minter precompile，所有 MAN 一次性预 mint，bridge 合约持有，**意味着 bridge 合约一旦被攻破等于发币上限被攻破**
- 没有 Avalanche / Cosmos 的协议层加持，安全完全靠自己

---

## 6. 决策矩阵

按"硬约束组合"选方案：

| 4 条硬约束（Ethereum L2 + 自定义 gas + 无费 + 节点少） | **OP Stack v6.0.0 + CGT v2 (P0)** — 唯一同时满足；接受"首批生产用户"风险 |
|---|---|
| 放弃"必须 L2"，要"最稳成熟" | Avalanche L1 (P1) |
| 放弃"无商业费"，要"最快上线 + 最久 GA" | Arbitrum Orbit + Ethereum parent (P1) |
| 接受 prover 复杂度，要 zk 安全偏好 | ZK Stack / Polygon CDK (P2) |
| 团队擅长 Cosmos SDK | Cosmos EVM (P3) |
| 团队只懂 go-ethereum，接受完全自维护 | 独立 PoSA + OFT（不推荐：节点重） |

---

## 7. 推荐：OP Stack v6.0.0 + CGT v2 + LayerZero 应用层桥

在 4 条硬约束（Ethereum L2 + 自定义 native gas + 无商业费 + 节点尽量少）下，**OP Stack v6.0.0 + CGT v2 是当前唯一同时满足的官方维护方案**。

### 7.1 硬约束契合度

| 约束 | 满足方式 |
|---|---|
| Ethereum L2 | rollup settle 到 Ethereum L1，DA 默认走 Ethereum calldata 或 EIP-4844 blob，可选 alt-DA（Celestia/EigenDA） |
| 自己 token 做 gas | `op-deployer init --intent-type custom` + `[chains.customGasToken]`，L2 创世铸出独立 native asset |
| 无商业费用 | OP Stack 本身没有 AEP 式 revenue share；OP Token Buyback 计划只对**自愿加入 Superchain 注册**的链生效，独立部署不入 Superchain 即可规避 |
| 节点尽量少 | sequencer (op-node + op-geth) + batcher + proposer 三个进程；challenger 可选；不需要任何外部 PoS 验证人集合 |

### 7.2 "BSC 上代币 = 本链原生 gas"在 v2 架构里的实现

CGT v2 不再是 v1 那种"L1 锁 ERC-20、L2 mint 等量 native"的字面映射，需要分两层设计：

```
┌─────────────────────────────────────────────────────────────────┐
│                       BSC Mainnet                                │
│                                                                  │
│   MyToken (BEP-20, 18 decimals)                                  │
│        │                                                         │
│        │  user calls bridge.lock(amount)                         │
│        ▼                                                         │
│   BridgeAdapter (LayerZero OApp 或 Hyperlane Mailbox)            │
│        │                                                         │
└────────┼─────────────────────────────────────────────────────────┘
         │   LayerZero / Hyperlane message
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                  MAN L2 (OP Stack v6.0.0, CGT v2)            │
│                                                                  │
│   L2 Receiver (custom OApp/Mailbox handler)                      │
│        │                                                         │
│        │  receiver.handle(msg) →                                 │
│        │    LiquidityController.mint(toUser, amount)             │
│        ▼                                                         │
│   LiquidityController (predeploy, governor-controlled)           │
│        │  从 NativeAssetLiquidity 划拨                            │
│        ▼                                                         │
│   NativeAssetLiquidity (predeploy, holds genesis-minted supply)  │
│        │                                                         │
│        ▼                                                         │
│   user 钱包余额：MAN（native gas）                                  │
│                                                                  │
│   Settles to Ethereum L1 via OptimismPortal (only ERC-20 deposit │
│   path; ETH 通过 L1-WETH 当 ERC-20 桥进，不再当 native)            │
└──────────────────────────────────────────────────────────────────┘
```

关键约束与设计点：

1. **18 decimals 强制**：CGT v2 当前只支持 18 位精度。BSC 上 MyToken 必须发成 18 decimals BEP-20，先确认。
2. **创世预 mint 总量**：决定一个上限（比如 type(uint248).max 或具体数额），全部铸到 `NativeAssetLiquidity`。该数额是"L2 侧理论可流通天花板"，不是真正流通。
3. **桥就是 minter**：`BridgeReceiver` 合约通过 `LiquidityController.authorizeMinter()` 拿到唯一 mint 权限，且要做 nonce/replay 防护（LayerZero 自带，但接收端逻辑必须 idempotent）。
4. **1:1 peg 由桥维持**：BSC 端 MyToken 锁仓余额 = L2 端 native 在外流通量。不能让任何**非桥路径**调用 `mint`。
5. **ETH 怎么办**：你的 L2 上 ETH 不再是 native；用户从 Ethereum L1 想用 ETH 时，先 wrap WETH，桥到 L2 后是普通 ERC-20 资产（不是 gas），UX 文档里要写清楚。
6. **桥的安全性 = 链的总安全性**：v1 时桥逻辑在 OptimismPortal 里、有 protocol-level 兜底；v2 桥在应用层，**桥被攻破等于 native gas 被无限增发**。强烈建议：
   - LayerZero DVN：至少 3-of-5，含 1 个自营 DVN
   - LiquidityController owner 用 Safe multisig + 时间锁
   - mint 速率限制 + 紧急暂停

### 7.3 节点拓扑（"尽可能少"的字面解读）

最小生产 footprint：

| 角色 | 进程 | 是否可合机 | 备注 |
|---|---|---|---|
| Sequencer execution | op-geth | 与 op-node 可同机 | 单点 |
| Sequencer consensus | op-node | 同上 | 单点 |
| Batcher | op-batcher | 可独立小机器 | 把 L2 batch 发到 L1 |
| Proposer | op-proposer | 同上 | 把 output root 提到 L1 |
| Challenger（可选） | op-challenger | 同上 | Fault Proof 启用时需要 |
| 公共 RPC | op-geth (replica) | ≥1 | 给用户/区块浏览器读 |

**最小 = 4 进程**（不开 fault proof + 自己也是唯一 RPC）；**生产推荐 = 6-7 进程**（含 challenger 和 1-2 RPC replica）。**没有任何 PoS 验证人集合**——这是 OP Stack 比 Cosmos / Avalanche / 自建 PoSA 节点重量级低的核心原因。

### 7.4 你"首批吃螃蟹"风险的真实样貌

不能美化的事实：

- U18 主网激活才 2.5 个月，截至 2026-04 没有公开命名的 production CGT v2 链
- `op-deployer v0.6.0` 的 `--intent-type custom` 路径上有过失败 issue（如 #13007、Discussion #662、#734），都集中在 2024-2025 年；当时多数是 legacy CGT v1 期的 bug，但 v2 路径上有多少坑还没被规模化暴露——**你的部署 PoC 必须严格按 v0.6.0 + v6.0.0 文档执行**，并准备好上 OP Labs Discord/GitHub 提 issue
- 你的桥代码是新代码，没有现成 reference，最好先做单 token 单方向 PoC

### 7.5 兜底分支

如果 PoC 阶段发现 OP Stack v6.0.0 + CGT v2 实际跑不通（部署 bug、官方支持不及时），**降级路线**：

1. **松动"无商业费"约束** → 切 Arbitrum Orbit + Ethereum parent，AEP 10% 是软性条款，最稳成熟（P1）
2. **松动"必须 L2"约束** → 切 Avalanche L1，技术上最简单（P1）
3. **接受 prover 复杂度** → 切 ZK Stack（P2）

这三条都是已经被验证过的备份路径，不会因为 OP Stack 单点失败就推不动项目。

---

## 8. 立即要做的 3 件事

1. **OP Stack v6.0.0 + CGT v2 部署 PoC（Sepolia，2 周）**
   - 严格按官方文档：`op-deployer v0.6.0` + `tag://op-contracts/v6.0.0` + `--intent-type custom`
   - 验收标准：
     - L1 SystemConfig.isCustomGasToken() == true
     - L2 L1Block.isCustomGasToken() == true
     - 创世后 NativeAssetLiquidity 余额 = 配置 initialLiquidity
     - 通过 LiquidityController.authorizeMinter + mint，能从无到有给一个 EOA 凭空打出 MAN 余额并用作 gas
     - OptimismPortal.depositTransaction{value: 1 ether}() 必须 revert
   - 失败 → 立刻评估 7.5 兜底分支

2. **桥设计与 token 起源策略**
   - 选定桥栈：LayerZero OApp（最熟）/ Hyperlane / 自建（不推荐）
   - 决定 BSC 端 MyToken：是新发还是已有？是否 18 decimals？
   - 决定 1:1 peg 维护方：BSC 端锁仓余额 vs L2 端流通量的对账机制
   - 设计 LiquidityController owner 治理：Safe multisig + 时间锁

3. **L2 经济参数预算**
   - `minBaseFee` 与 `operatorFee` 必须按 MyToken 计价精确算 L1 gas + DA 成本，否则要么链亏要么用户骂；建一个动态调价 runbook（用 SystemConfig.setGasConfig()）

---

## 9. 参考资料

### OP Stack v6.0.0 + CGT v2（P0 主推）
- [Custom Gas Token 概览](https://docs.optimism.io/op-stack/features/custom-gas-token)
- [部署指南：Deploy a Custom Gas Token chain](https://docs.optimism.io/chain-operators/guides/features/custom-gas-token-guide)
- [Upgrade 18 治理提案](https://vote.optimism.io/proposals/77621298185123846119233191553645120427678039792258174752758738057653049982021)
- [op-deployer 文档](https://docs.optimism.io/chain-operators/tools/op-deployer/overview)
- [op-deployer state 包（intent.toml schema）](https://pkg.go.dev/github.com/ethereum-optimism/optimism/op-deployer/pkg/deployer/state)
- [Network upgrades 时间表](https://docs.optimism.io/op-stack/protocol/network-upgrades)
- 已知历史 issue（部署排错时参考）：
  - [#13327 impossible to deploy a custom gas token enabled chain（legacy CGT v1，已关）](https://github.com/ethereum-optimism/optimism/issues/13327)
  - [#13007 Issues after Deploying Custom Gas Token L2 Chain](https://github.com/ethereum-optimism/optimism/issues/13007)
  - [Discussion #662 L2 with custom gas token but getting Wrapped Ether](https://github.com/ethereum-optimism/developers/discussions/662)
  - [Discussion #734 op-deployer apply ERROR](https://github.com/ethereum-optimism/developers/discussions/734)

### Avalanche L1
- [Avalanche L1 自定义指南](https://docs.avax.network/docs/avalanche-l1s/evm-configuration/customize-avalanche-l1)
- [Native Minter Precompile](https://build.avax.network/docs/avalanche-l1s/precompiles/native-minter)
- [Fee Manager Precompile](https://build.avax.network/docs/avalanche-l1s/precompiles/fee-manager)
- [Avalanche-CLI](https://github.com/ava-labs/avalanche-cli)
- [Subnet-EVM 仓库](https://github.com/ava-labs/subnet-evm)
- [ACP-224 动态 gas 算法](https://docs.avax.network/docs/acps/224-dynamic-gas-limit-in-subnet-evm)
- [2022 ERC-20 桥到 Subnet 教程](https://docs.avax.network/deprecated/tutorials-contest/2022/erc20-as-subnet-gas-token)（基础但仍有参考价值）

### LayerZero OFT
- [OFT Standard 文档](https://docs.layerzero.network/v2/home/token-standards/oft-standard)
- [OFT Variants（含 BurnMint / LockUnlock / Native / Alt）](https://docs.layerzero.network/v2/developers/evm/stablecoin-oft/ofts)
- [MintBurnOFTAdapter 源码](https://github.com/LayerZero-Labs/devtools/blob/main/packages/oft-evm/contracts/MintBurnOFTAdapter.sol)

### Cosmos EVM
- [Cosmos EVM 文档](https://evm.cosmos.network/evm/latest/documentation/evm-compatibility)
- [cosmos/evm 仓库](https://github.com/cosmos/evm)
- [Axelar EVM↔Cosmos GMP](https://docs.axelar.dev/dev/general-message-passing/cosmos-gmp/developer-guides/cross-chain-messaging-evm-to-cosmos)

### Production 案例
- [DeFi Kingdoms Subnet](https://docs.defikingdoms.com/getting-started/dfk-chain)
- [Beam Network](https://docs.onbeam.com/)
- [Dexalot](https://docs.dexalot.com/)
- [GUN by Off The Grid](https://www.offthegrid.gg/)
