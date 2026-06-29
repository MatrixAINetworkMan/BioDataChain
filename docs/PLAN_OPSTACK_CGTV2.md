# MAN L2 实施计划书 — OP Stack v6.0.0 + CGT v2

> 版本: v1.1 · 日期: 2026-04-22
> 技术选型依据: `docs/PLAN_ALTERNATIVES.md` §7
> 目标读者: 项目负责人 + 1-2 名 DevOps + 1 名 Solidity/桥工程师
> 工期估算: B 本地 dev = **3-5 天** · C Sepolia PoC = **2 周** · D 主网上线 = **+2-3 周**

---

## 0. 这份计划书怎么用

### 0.1 三阶段路线（强烈推荐）

为了把"踩坑"和"花真钱"完全分开，部署分三步走：

| 阶段 | 名字 | L1 是什么 | 花费 | 目的 |
|---|---|---|---|---|
| **B** | 本地 dev | 单机跑的 anvil（假以太坊） | **0** | 跑通 op-deployer + CGT v2 + 4 个 OP 服务，验证 intent.toml |
| **C** | Sepolia 公测 | Sepolia 公测网 | **0**（faucet 领 ~1 ETH） | 团队/审计访问；验证桥；接钱包；上 chainlist |
| **D** | 主网 | Ethereum mainnet | 部署 ~0.3 ETH + 月运营 0.5-1.5 ETH | 真正生产 |

**核心 insight**：B → C 只改 `.env` 4 行，其余代码完全复用；C → D 同理。即"本地 100% 跑通的链，上 Sepolia 是改 4 行配置"。所以 B 阶段是真正的全功能预演。

> **你现在在哪一步**：B 阶段的脚手架已就绪，见 [`dev/`](../dev/) 目录和 [`dev/README.md`](../dev/README.md)。一行 `make dev-up` 就能拉起。

### 0.2 章节顺序

按章节顺序往下走，每一章末尾都有 **"做完这章你应该看到什么"** 的明确产出。任何一章产出对不上，**先停**，按 §11 的故障排查表排错，不要往下推。

| 章节 | 主题 | 时间 | 关键产出 |
|---|---|---|---|
| §1 | 准备工作 | 2 天 | 所有账号、密钥、域名、工具链就绪 |
| §2 | 硬件环境 | 1 天 | 4 台机器 / 1 台多容器都可，按表格采购 |
| **§3** | **B 阶段：本地 dev（必跑）** | **0.5 天** | **`dev/` 一键拉起，CGT v2 验收 10 条全过** |
| §3.5 | C 阶段：Sepolia 部署 | 0.5 天 | `make all-sepolia` 跑完，链出块 |
| §4 | BSC ↔ L2 桥 | 5 天 | MyToken 在 BSC 锁仓，L2 钱包有 native 余额 |
| §5 | 区块浏览器（Blockscout） | 1 天 | https://explorer.man.xxx 能查到交易 |
| §6 | 钱包接入（MetaMask + Rabby） | 0.5 天 | 用户能 add network、看到 MAN 余额、发交易 |
| §7 | 监控与告警 | 1 天 | Grafana 三块大盘、5 条核心告警 |
| §8 | 主网上线 checklist | 2 天 | 24 项卡控全部 ✅ |
| §9 | 验收标准 | 0.5 天 | 38 条验收用例 100% 通过 |

---

## 1. 准备工作

### 1.1 账号与服务

| 项 | 用途 | 是否必需 | 备注 |
|---|---|---|---|
| GitHub 账号 + 私有仓 | 存配置、密钥（加密）、IaC | 必需 | 推荐 GitHub Actions 跑部署 |
| 域名 1 个（如 man.xxx） | RPC、explorer、bridge UI 子域 | 必需 | DNS 解析能改 A/CNAME |
| Cloudflare 账号 | 反向代理 + DDoS + WAF | 强烈推荐 | 免费版够用 |
| Sepolia ETH ≥ 5 ETH | 部署 L1 合约 + batcher/proposer 长期 gas | 必需 | 从 https://sepoliafaucet.com 或 https://www.alchemy.com/faucets/ethereum-sepolia 领 |
| BSC Testnet BNB ≥ 0.5 BNB | 在 BSC 部署 MyToken + 桥合约 | 必需 | https://testnet.bnbchain.org/faucet-smart |
| Etherscan API Key | 验证 L1 合约 | 推荐 | https://etherscan.io/apis |
| BscScan API Key | 验证 BSC 端合约 | 推荐 | https://bscscan.com/myapikey |
| Alchemy / Infura / QuickNode 账号 | Sepolia + Mainnet RPC | 必需 | **不要用公共 RPC**，部署会一直 nonce 错乱 |
| LayerZero scan key（可选） | 监控桥消息 | 可选 | https://docs.layerzero.network/ |
| Sentry / Loki | 错误日志聚合 | 推荐 | self-host 或 SaaS 都行 |

### 1.2 密钥规划

**绝对不要** 在任何脚本里硬编码私钥。准备 5 个独立 EOA：

| 角色 | 用途 | 资金需求 | 安全级别 |
|---|---|---|---|
| `DEPLOYER` | 部署 L1 合约（一次性） | 5 ETH (Sepolia) / 1 ETH (主网) | 部署完即冷藏 |
| `BATCHER` | 持续提交 batch 到 L1 | 月均 0.3-1 ETH | 热钱包，需自动续费 |
| `PROPOSER` | 持续提交 output root 到 L1 | 月均 0.05-0.2 ETH | 热钱包 |
| `CHALLENGER`（可选） | Fault proof 启用时挑战错误 root | 备用 0.5 ETH | 热钱包 |
| `SEQUENCER` | unsafeBlockSigner，签 L2 区块（不付 gas） | 0 | **最高级**，丢了等于链被劫持 |

生成命令（任何一台干净的 Linux/Mac）：

```bash
mkdir -p secrets && chmod 700 secrets
for role in DEPLOYER BATCHER PROPOSER CHALLENGER SEQUENCER; do
  cast wallet new --json | tee "secrets/${role}.json"
done
```

把 5 个 JSON 文件用 GPG 或 `age` 加密，放进私有仓 `secrets/` 目录（用 `git-crypt` 或 `sops` 管理）。

**生产建议**：BATCHER / PROPOSER 用 **AWS KMS** 或 **GCP Cloud KMS** 托管密钥，op-batcher / op-proposer 都原生支持 `--signer.endpoint` 远程签名。SEQUENCER 用 HSM 或硬件钱包。

### 1.3 工具链（本机开发机一次性）

```bash
# Foundry（cast/forge）
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Docker + Docker Compose
# Mac: brew install --cask docker
# Linux: curl -fsSL https://get.docker.com | sh

# jq, yq, just（任务编排）
# Mac: brew install jq yq just
# Linux: apt install -y jq && pip install yq && cargo install just

# op-deployer v0.6.0（这是核心工具）
go install github.com/ethereum-optimism/optimism/op-deployer/cmd/op-deployer@op-deployer/v0.6.0
# 验证
op-deployer --version  # 应输出 v0.6.0
```

### 1.4 决策清单（动手前必须填完）

把下面这张表填完再开干，否则中间停下来改参数代价很大。

| 参数 | 你的取值 | 备注 |
|---|---|---|
| L2 名称 | `MAN` | 显示用 |
| L2 Chain ID | `???`（建议 4 位以上随机，避开已用 ID） | https://chainlist.org 查重 |
| Native asset 名称 | `Matrix AI Network` | 钱包显示 |
| Native asset symbol | `MAN` | 钱包显示 |
| Native asset 创世总量 | `2_000_000_000 ether`（20 亿） | 全部铸到 NativeAssetLiquidity |
| BSC 上 MyToken 总量上限 | `2_000_000_000` | **必须 = L2 创世量**，否则桥会破 peg |
| BSC 端 MyToken decimals | `18` | **CGT v2 强制 18 位** |
| L1（settle 层） | Sepolia → 主网 Ethereum | **不要用 BSC，OP Stack v6.0.0 主线只对 Ethereum 验证过** |
| 出块时间 | `3s` | 默认 3s |
| Gas limit | `60_000_000` | 默认 |
| DA 类型 | `EIP-4844 blob`（默认） | 主网建议 blob，Sepolia 也支持 |
| Proxy admin owner | `0x...` Safe 多签 3-of-5 | **不要用 EOA** |
| Liquidity controller owner | `0x...` Safe 多签 3-of-5 | **不要用 EOA** |
| 桥技术栈 | LayerZero V2（推荐）/ Hyperlane | 决定 §4 实现 |
| 浏览器 | Blockscout（推荐）/ 自建 | 决定 §5 |

**做完这章你应该看到**：一个 `prep-checklist.md` 文件全部勾选完成，5 个加密密钥文件入仓，BSC + Sepolia 都有钱。

---

## 2. 硬件环境需求及配置

### 2.1 Sepolia PoC 阶段（最小）

可以**全部塞一台机器**用 docker-compose 跑：

| 资源 | 配置 | 备注 |
|---|---|---|
| CPU | 8 vCPU | Intel/AMD 64-bit |
| 内存 | 32 GB | op-geth cache 给 16GB，剩下分给其他 |
| 系统盘 | 100 GB SSD | OS + Docker images |
| 数据盘 | 500 GB NVMe SSD | op-geth 状态数据，PoC 期增长慢 |
| 网络 | 100 Mbps，固定 IP | 必须能稳定访问 Sepolia RPC |
| OS | Ubuntu 22.04 LTS | 推荐 |

**云厂商参考**：
- AWS: `m6i.2xlarge` + 500GB gp3 ≈ $300/月
- 阿里云: `ecs.g7.2xlarge` + 500GB ESSD PL1 ≈ ¥1500/月
- Hetzner: `AX42` (Ryzen 5950X / 64GB / 2x1TB NVMe) ≈ €60/月（性价比之王）

### 2.2 主网上线阶段（推荐）

按角色拆 4 台机器，避免单点：

| 机器 | 角色 | CPU | 内存 | 数据盘 | 网络 |
|---|---|---|---|---|---|
| **node-1** | sequencer (op-geth + op-node) | 16 vCPU | 64 GB | 2 TB NVMe | 1 Gbps，固定 IP，地理位置接近 L1 RPC |
| **node-2** | batcher + proposer (+ challenger) | 4 vCPU | 8 GB | 100 GB SSD | 100 Mbps |
| **node-3** | RPC replica（公开 RPC + Blockscout backend） | 16 vCPU | 64 GB | 2 TB NVMe | 1 Gbps，扛流量 |
| **node-4** | Blockscout + DB + indexer + 监控（Prometheus/Grafana/Loki） | 8 vCPU | 32 GB | 1 TB SSD | 100 Mbps |

**为什么这么分**：
- sequencer 单点不可降级（OP Stack 当前还没有去中心化 sequencer），但 batcher/proposer 是无状态、可重启的
- RPC replica 与 sequencer 隔离，避免外部恶意流量打垮出块
- 监控独立机器是为了链宕掉时还能看到为什么宕

### 2.3 系统级配置（每台机器都做）

```bash
sudo timedatectl set-timezone UTC
sudo apt update && sudo apt upgrade -y

sudo apt install -y ca-certificates curl gnupg lsb-release ufw fail2ban htop iotop

curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
case "$ROLE" in
  node-1) sudo ufw allow 9222/tcp ;;          # p2p 9222
  node-3) sudo ufw allow 443/tcp ;;            # 公开 RPC（走 Cloudflare）
  node-4) sudo ufw allow 443/tcp ;;            # 浏览器（走 Cloudflare）
esac
sudo ufw --force enable

cat <<EOF | sudo tee -a /etc/sysctl.conf
fs.file-max = 1048576
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
vm.swappiness = 1
vm.max_map_count = 262144
EOF
sudo sysctl -p

cat <<EOF | sudo tee /etc/security/limits.d/99-man.conf
* soft nofile 1048576
* hard nofile 1048576
EOF
```

**做完这章你应该看到**：4 台机器 ssh 通，docker 可用，防火墙生效，时区 UTC，磁盘可写。

---

## 3. B 阶段：本地 dev 一键拉起（必跑）

> **这是整份计划书最重要的一节。Sepolia 阶段的所有问题，都应该先在本地 dev 复现并解决。**

### 3.0 你已经有什么

`dev/` 目录里已经写好了完整的脚手架，对应仓库结构：

```
man/dev/
├── Makefile                      # 入口（make help 看命令）
├── .env.example                  # cp .env.example .env 后改
├── intent.toml.example           # CGT v2 配置模板（envsubst 渲染）
├── docker-compose.yml            # anvil + op-deployer + op-geth/node/batcher/proposer + Blockscout
├── README.md                     # AWS 远程机一条龙指南
└── scripts/
    ├── 00-check-env.sh           # 环境校验
    ├── 00-render-intent.sh       # 渲染 intent.toml
    ├── 01-deploy-l1.sh           # op-deployer apply（L1 合约）
    ├── 02-deploy-genesis.sh      # 生成 genesis.json + rollup.json
    ├── wait-for.sh
    ├── healthcheck.sh            # 6 项端到端检查
    ├── info.sh                   # 打印外部访问 URL
    └── verify-cgt.sh             # CGT v2 10 项验收（核心！）
```

### 3.1 在 AWS 机器上跑

按 [`dev/README.md`](../dev/README.md) 的 §3-5 走，约 15 分钟：

```bash
cd ~/man/dev
cp .env.example .env
sed -i 's/^PUBLIC_HOST=.*/PUBLIC_HOST=<aws-public-ip>/' .env
make pull        # 预拉镜像
make dev-up      # 一键拉起全套
make verify-cgt  # 跑 10 项 CGT v2 验收
```

### 3.2 验收门槛（B 阶段才算过）

`make verify-cgt` 必须 10 / 10 通过：

1. ✅ 原生币 symbol = MAN（intent 配置生效）
2. ✅ `L1Block.isCustomGasToken() == true`
3. ✅ `NativeAssetLiquidity` (0x4200..0020) 创世余额 > 0
4. ✅ `LiquidityController` (0x4200..0021) 已部署
5. ✅ Deployer EOA 在 L2 有 initialLiquidity 余额
6. ✅ 原生币转账成功，对方余额增加
7. ✅ tx receipt 的 `effectiveGasPrice` * `gasUsed` 以 MAN 计价
8. ✅ 零余额账户发交易被 RPC 拒绝（`insufficient funds`）
9. ✅ op-batcher 在向 anvil 提交 batch
10. ✅ op-node 的 safe / unsafe head 差距 < 100 块（说明 batch 在被消费）

> **B 没全过就不要进 C**。Sepolia 上同样的问题排查成本是 10 倍。

### 3.3 B → C 的差异（只需改 4 行）

切换到 Sepolia 时，`dev/.env` 改 4 行：

```diff
-L1_CHAIN_ID=901
-L1_RPC_URL_INTERNAL=http://anvil:8545
-L1_RPC_URL_EXTERNAL=http://anvil:8545
-BATCHER_DA_TYPE=calldata
+L1_CHAIN_ID=11155111
+L1_RPC_URL_INTERNAL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
+L1_RPC_URL_EXTERNAL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
+BATCHER_DA_TYPE=auto
```

加上把 5 个角色私钥从 anvil 公开 key 替换为真实 key、`OWNER_MULTISIG` 换成 Safe 多签，再 `make dev-clean && make dev-up` 即可。详见 §3.5。

---

## 3.5 C 阶段：Sepolia PoC（一键安装）

这是 B 跑通后的第二步。所有手动步骤封装进 `Makefile`，目标是**一条命令把链拉起来**。

### 3.5.1 仓库结构（用这套替换当前 opBNB 版本）

```
man/
├── Makefile                      <- 入口，所有命令在这
├── .env.example                  <- 抄成 .env 填值
├── intent.toml                   <- op-deployer CGT v2 配置
├── deploy/
│   ├── 01-init-intent.sh
│   ├── 02-apply-l1.sh
│   ├── 03-apply-genesis.sh
│   └── 04-emit-rollup-config.sh
├── docker/
│   ├── compose.yml               <- 4 个 OP 服务 + Blockscout + 监控
│   ├── Dockerfile.opnode
│   ├── Dockerfile.opgeth
│   └── env/
├── contracts/
│   ├── bsc/
│   │   ├── MyToken.sol           <- BSC 上 18-decimal BEP-20
│   │   └── BridgeSender.sol      <- LayerZero OApp，BSC 端
│   └── l2/
│       ├── BridgeReceiver.sol    <- LayerZero OApp，L2 端，是 LiquidityController authorized minter
│       └── interfaces/ILiquidityController.sol
├── scripts/
│   ├── one-click-sepolia.sh      <- §3.4 的实现
│   ├── healthcheck.sh
│   └── mint-test.sh              <- 跑一次端到端 mint 验收
├── monitoring/
│   ├── prometheus.yml
│   ├── grafana-dashboards/
│   └── alerts.yml
└── docs/
```

### 3.2 `intent.toml`（CGT v2 部署的灵魂）

按 §1.4 决策清单填空，这是 `op-deployer` 直接消费的文件：

```toml
configType            = "custom"
l1ChainID             = 11155111   # Sepolia；主网换 1
fundDevAccounts       = false
useInterop            = false
l1ContractsLocator    = "tag://op-contracts/v6.0.0"
l2ContractsLocator    = "tag://op-contracts/v6.0.0"

[superchainRoles]
  SuperchainProxyAdminOwner = "0xYOUR_SAFE_MULTISIG"
  SuperchainGuardian        = "0xYOUR_SAFE_MULTISIG"
  ProtocolVersionsOwner     = "0xYOUR_SAFE_MULTISIG"
  Challenger                = "0xYOUR_SAFE_MULTISIG"

[[chains]]
  id                          = "0x000000000000000000000000000000000000000000000000000000000000XXXX"  # = 你的 L2 chain ID hex
  baseFeeVaultRecipient       = "0xYOUR_FEE_RECIPIENT"
  l1FeeVaultRecipient         = "0xYOUR_FEE_RECIPIENT"
  sequencerFeeVaultRecipient  = "0xYOUR_FEE_RECIPIENT"
  operatorFeeVaultRecipient   = "0xYOUR_FEE_RECIPIENT"
  eip1559DenominatorCanyon    = 250
  eip1559Denominator          = 50
  eip1559Elasticity           = 6
  gasLimit                    = 60000000
  operatorFeeScalar           = 0
  operatorFeeConstant         = 0
  minBaseFee                  = 1
  daFootprintGasScalar        = 0

  [chains.roles]
    l1ProxyAdminOwner   = "0xYOUR_SAFE_MULTISIG"
    l2ProxyAdminOwner   = "0xYOUR_SAFE_MULTISIG"
    systemConfigOwner   = "0xYOUR_SAFE_MULTISIG"
    unsafeBlockSigner   = "0xYOUR_SEQUENCER_EOA"
    batcher             = "0xYOUR_BATCHER_EOA"
    proposer            = "0xYOUR_PROPOSER_EOA"
    challenger          = "0xYOUR_SAFE_MULTISIG"

  [chains.customGasToken]
    name                   = "Matrix AI Network"
    symbol                 = "MAN"
    initialLiquidity       = "0x6765c793fa10079d0000000"   # 2e27 wei = 2e9 * 1e18，可改
    liquidityControllerOwner = "0xYOUR_SAFE_MULTISIG"
```

### 3.3 `Makefile`

```makefile
SHELL := /usr/bin/env bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

include .env
export

.PHONY: help all-sepolia clean status logs

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

all-sepolia: tools intent deploy-l1 genesis rollup-config docker-up wait-block status ## 一键完成 Sepolia 部署
	@echo "✅ MAN L2 (Sepolia) 已上线"

tools: ## 安装/检查依赖
	@bash scripts/check-tools.sh

intent: ## 生成 intent.toml（首次）
	@op-deployer init --l1-chain-id $(L1_CHAIN_ID) --l2-chain-ids $(L2_CHAIN_ID) --intent-type custom
	@echo "✏️  现在编辑 intent.toml 填入决策清单的值，然后回车继续"
	@read -r

deploy-l1: ## 部署 L1 合约到 Sepolia
	@op-deployer apply --l1-rpc-url $(L1_RPC_URL) --private-key $(DEPLOYER_PRIVATE_KEY) --workdir .
	@cp .deployer/state.json deploy-state.sepolia.json
	@echo "✅ L1 合约已部署，状态写入 deploy-state.sepolia.json"

genesis: ## 生成 L2 genesis & rollup
	@op-deployer apply --deployment-target genesis --workdir .
	@cp .deployer/genesis-$(L2_CHAIN_ID).json   docker/data/genesis.json
	@cp .deployer/rollup-$(L2_CHAIN_ID).json    docker/data/rollup.json
	@openssl rand -hex 32 > docker/data/jwt.txt
	@echo "✅ genesis.json / rollup.json / jwt.txt 已生成"

rollup-config: ## 把 L1 合约地址写回 .env
	@bash scripts/sync-deploy-state.sh

docker-up: ## 拉起所有服务
	@cd docker && docker compose --profile init run --rm op-geth-init
	@cd docker && docker compose up -d
	@echo "✅ 容器已启动"

wait-block: ## 等待出第一个块
	@bash scripts/wait-for-block.sh 1 300

status: ## 显示当前状态
	@bash scripts/healthcheck.sh

logs: ## tail 所有服务日志
	@cd docker && docker compose logs -f --tail=100

clean: ## 清理（危险）
	@cd docker && docker compose down -v
	@rm -rf .deployer docker/data/genesis.json docker/data/rollup.json docker/data/jwt.txt
```

### 3.4 一键脚本 `scripts/one-click-sepolia.sh`

```bash
#!/usr/bin/env bash
# 适合 demo / 临时环境。生产请走 §3.3 Makefile 分步执行
set -euo pipefail

cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "缺少 .env，请 cp .env.example .env 并填值"; exit 1; }
[[ -f intent.toml ]] || { echo "缺少 intent.toml，先运行 make intent"; exit 1; }

make tools
make deploy-l1
make genesis
make rollup-config
make docker-up
make wait-block
make status

echo ""
echo "========================================================"
echo "  ✅ 部署完成"
echo "  RPC:        http://localhost:8545"
echo "  WS:         ws://localhost:8546"
echo "  Explorer:   http://localhost:4000"
echo "  Grafana:    http://localhost:3000"
echo "========================================================"
```

### 3.5 真正的"一键"使用流程

机器准备好 + 1.4 决策清单填完后，使用者只要：

```bash
git clone <your-private-repo> man && cd man

cp .env.example .env
$EDITOR .env                  # 填 RPC URL、私钥、L2 chain ID

make intent                   # 生成 intent.toml 模板
$EDITOR intent.toml           # 把决策清单的值填进去（一次性）

./scripts/one-click-sepolia.sh
```

整个过程在一台 8C32G + 500GB SSD 的 Sepolia 机器上 **~25 分钟**（其中 op-deployer 部署 L1 合约 ~10 分钟，docker pull + 构建 ~10 分钟，等待出块 ~3 分钟）。

### 3.6 docker compose 关键服务清单

`docker/compose.yml` 包含：

- `op-deployer-init`（profile init，跑一次） — 用 op-deployer 把 genesis / rollup 注入 op-geth
- `op-geth` — 执行客户端，挂 native CGT v2 predeploys
- `op-node` — 共识/排序，sequencer 模式
- `op-batcher` — 提交 batch 到 Sepolia
- `op-proposer` — 提交 output root
- `op-challenger`（可选，profile fault-proof）
- `blockscout-backend` + `blockscout-frontend` + `postgres` + `redis`
- `prometheus` + `grafana` + `loki` + `promtail`

镜像版本 pin 到 `op-contracts/v6.0.0` 对应的 release：

```yaml
services:
  op-geth:
    image: us-docker.pkg.dev/oplabs-tools-artifacts/images/op-geth:v1.101511.0
  op-node:
    image: us-docker.pkg.dev/oplabs-tools-artifacts/images/op-node:v1.13.0
  op-batcher:
    image: us-docker.pkg.dev/oplabs-tools-artifacts/images/op-batcher:v1.13.0
  op-proposer:
    image: us-docker.pkg.dev/oplabs-tools-artifacts/images/op-proposer:v1.13.0
```

> 部署前到 https://github.com/ethereum-optimism/optimism/releases 核对 op-contracts/v6.0.0 当前对应的最新 op-* binary tag，写到 `.env` 里 pin 死。

**做完这章你应该看到**：
- `make status` 输出 L2 区块号 > 0，且 1 秒一块持续在涨
- `cast block-number --rpc-url http://localhost:8545` 返回数字
- `cast balance 0x000...0001 --rpc-url http://localhost:8545` 返回非零（NativeAssetLiquidity 余额）

---

## 4. BSC ↔ L2 桥（CGT v2 应用层桥）

CGT v2 不在协议层桥 L1 ERC-20，所以这一层**必须自己写**。

### 4.1 拓扑

```
┌──────────────────── BSC ────────────────────┐         ┌──────────────── MAN L2 ────────────────┐
│  MyToken (18d BEP-20)                       │         │  NativeAssetLiquidity  (predeploy)         │
│        │ approve + lock                     │         │        ▲ withdraw                          │
│        ▼                                    │         │        │                                   │
│  BridgeSender (LayerZero OApp)              │  msg    │  LiquidityController   (predeploy)         │
│        │ _lzSend(MANRACHAIN_EID, payload)      │ ─────► │        ▲ mint(to, amt)                    │
│                                             │         │        │ (callable only by authorized)    │
│                                             │  msg    │  BridgeReceiver (your OApp)               │
│        ◄─────────────────────────────────── │         │        ▲ _lzReceive                       │
│  unlock + transfer                          │         │  user 钱包 native 余额 + 1 MAN             │
└─────────────────────────────────────────────┘         └────────────────────────────────────────────┘
```

### 4.2 部署顺序

1. **BSC 上**：部署 `MyToken`（18 decimals，固定总量），所有 supply 一次性 mint 到一个"金库 EOA"
2. **BSC 上**：部署 `BridgeSender`（LayerZero OApp，配 LayerZero V2 endpoint）
3. **L2 上**：部署 `BridgeReceiver`（LayerZero OApp）
4. **L2 上**：用 LiquidityController owner（Safe 多签）调 `LiquidityController.authorizeMinter(BridgeReceiver)`
5. **双向**：分别在 sender / receiver 上调 `setPeer()` 互相绑定

### 4.3 1:1 peg 不变式

任何代码合并到主分支前，必须确保：

```
BSC.MyToken.balanceOf(BridgeSender)  ==  L2.NativeAssetLiquidity.initialMintedSupply - L2.NativeAssetLiquidity.balance
```

也即：BSC 端锁了多少 token，L2 端就有多少 native 在外流通。

实现要点：
- BSC 端 `lock(amount)` 必须先 `transferFrom(user, address(this), amount)` 再 `_lzSend(...)`
- L2 端 `_lzReceive(payload)` 解码出 `(to, amount)` 后调 `LiquidityController.mint(to, amount)`，**不**再做任何动态的 supply 检查（peg 由 BSC 端保证）
- 反向 unlock：用户在 L2 调 `BridgeReceiver.burn(amount)` → `LiquidityController.burn` → `_lzSend` 给 BSC → BSC 端 `transfer(user, amount)`

### 4.4 安全清单（在 §8 主网 checklist 里复用）

- [ ] LayerZero DVN 至少 3-of-5，含 1 个自营 DVN
- [ ] BridgeReceiver 与 BridgeSender 各自 owner 是 Safe 3-of-5
- [ ] mint 速率限制：单 tx 上限 + 每小时上限（hard cap = 总量的 0.5%）
- [ ] 紧急暂停：BridgeSender / BridgeReceiver 都实现 `Pausable`，由 Safe 触发
- [ ] 桥事件全量上 Sentry，异常自动告警
- [ ] 部署前必须有第三方 audit（推荐 Spearbit / Cantina / Code4rena 任一）

**做完这章你应该看到**：在 BSC testnet 上 `cast send MyToken.transfer(BridgeSender, 1 ether)` + `cast send BridgeSender.lock(1 ether)`，5 分钟内 L2 上目标地址 `cast balance` 多出 ~1 ether。

---

## 5. 区块浏览器（Blockscout）

OP Stack 生态默认是 Blockscout（开源、免费、原生支持 OP Stack 的 deposit/withdraw 视图），不要去碰收费的。

### 5.1 一键拉起

```bash
git clone https://github.com/blockscout/blockscout.git
cd blockscout/docker-compose

cp envs/common-blockscout.env envs/man.env
$EDITOR envs/man.env
```

关键变量（`envs/man.env`）：

```
ETHEREUM_JSONRPC_HTTP_URL=http://node-3-internal:8545     # 指向你的 RPC replica
ETHEREUM_JSONRPC_WS_URL=ws://node-3-internal:8546
ETHEREUM_JSONRPC_TRACE_URL=http://node-3-internal:8545
CHAIN_ID=<你的 L2 chain ID>
COIN_NAME=MAN
COIN=MAN
SUBNETWORK=MAN
LOGO=/images/man.png

CHAIN_TYPE=optimism
INDEXER_OPTIMISM_L1_RPC=https://ethereum.publicnode.com    # 主网；Sepolia 换对应 RPC
INDEXER_OPTIMISM_L1_BATCH_INBOX=<batchInbox 地址，从 deploy-state 读>
INDEXER_OPTIMISM_L1_BATCH_BLOCKSCOUT_BLOBS_API_URL=
INDEXER_OPTIMISM_L1_PORTAL_CONTRACT=<OptimismPortalProxy 地址>
INDEXER_OPTIMISM_L1_DEPOSITS_BATCH_SIZE=500
INDEXER_OPTIMISM_L1_DEPOSITS_TRANSACTION_TYPE=126
INDEXER_OPTIMISM_L1_OUTPUT_ORACLE_CONTRACT=<L2OutputOracleProxy>
INDEXER_OPTIMISM_L1_SYSTEM_CONFIG_CONTRACT=<SystemConfigProxy>
INDEXER_OPTIMISM_L2_MESSAGE_PASSER_CONTRACT=0x4200000000000000000000000000000000000016
```

启动：

```bash
docker compose -f geth.yml up -d
```

5-10 分钟 indexer 追上后，访问 `http://node-4:80`，应能看到：
- 区块列表实时滚动
- 每笔交易的 gas 用 **MAN**（不是 ETH）显示
- 顶部菜单有 "Deposits" / "Withdrawals" 两个 OP 专属页

### 5.2 反代 + HTTPS

在 node-4 前面挂 Cloudflare：

```
explorer.man.xxx  →  CNAME  →  node-4-public-ip
```

Cloudflare 上开 SSL Full Strict，回源 HTTP 到 node-4:80，免费证书自动管。

### 5.3 自定义品牌（可选）

把 `apps/block_scout_web/assets/static/images/man.png` 放进去，改 `LOGO` 环境变量；改 `block_scout_web` 的 i18n 文件改"Ether" → "MAN"（CGT v2 模板已经会做大部分替换，但有些角落要手改）。

**做完这章你应该看到**：浏览器访问 https://explorer.man.xxx 能搜到任意区块/地址/交易，gas 显示 MAN，deposit/withdraw 视图能看到桥消息。

---

## 6. 钱包接入

### 6.1 MetaMask / Rabby（用户侧）

提供一个 "Add MAN Network" 按钮，点击调 `wallet_addEthereumChain`：

```js
await window.ethereum.request({
  method: "wallet_addEthereumChain",
  params: [{
    chainId: "0xYOUR_HEX_CHAIN_ID",
    chainName: "MAN",
    nativeCurrency: { name: "Matrix AI Network", symbol: "MAN", decimals: 18 },
    rpcUrls: ["https://rpc.man.xxx"],
    blockExplorerUrls: ["https://explorer.man.xxx"],
    iconUrls: ["https://man.xxx/logo.png"]
  }]
});
```

把这个按钮放在 https://man.xxx 首页和 https://docs.man.xxx/get-started。

### 6.2 公开 RPC

node-3 后面挂 Cloudflare + 限流：

```
rpc.man.xxx  →  Cloudflare  →  node-3:8545
```

Cloudflare WAF 规则：
- 每 IP 每秒 ≤ 30 RPC
- block 已知扫描器 user-agent
- 屏蔽 `eth_subscribe`（websocket 走单独子域 `ws.man.xxx`）

⚠️ 公开 RPC 必须**屏蔽**这些方法（在 op-geth 启动时用 `--http.api` 白名单）：
- `personal_*`
- `admin_*`
- `debug_traceTransaction`（贵，单独走付费 RPC）
- `miner_*`

推荐 `--http.api=eth,net,web3,txpool,engine`。

### 6.3 chainlist.org 收录

部署稳定 1 周后到 https://github.com/ethereum-lists/chains 提 PR，把 MAN 加入官方列表。一旦 merge，用户能在 chainlist.org 一键加到钱包。

### 6.4 钱包侧的 native gas 显示问题

CGT v2 把 native asset 直接命名为 MAN，MetaMask / Rabby / OKX Wallet **不需要任何额外配置**，余额会自动显示 "MAN"。这点比 Avalanche L1 要轻松（那边历史上有些钱包要手动添加 chain metadata 才能正确显示）。

**做完这章你应该看到**：在干净的 MetaMask 里点你的"Add Network"按钮 → 自动添加 → 余额栏显示 "0 MAN" → 别人转你 1 MAN → 显示 "1 MAN" → 发交易时 gas 显示用 MAN 计费。

---

## 7. 监控与告警

### 7.1 必看的 5 个指标 + 告警阈值

| 指标 | PromQL（示意） | 阈值 | 严重度 |
|---|---|---|---|
| L2 出块停滞 | `time() - max(op_node_default_unsafe_l2_head_timestamp)` | > 30s | P0 立即叫人 |
| Sequencer ↔ L1 RPC 失败率 | `rate(op_node_default_l1_request_errors_total[5m])` | > 0.05 | P1 |
| Batcher 提交延迟（safe 落后 unsafe） | `op_node_default_unsafe_l2_head_block - op_node_default_safe_l2_head_block` | > 600 块 | P1 |
| Proposer 余额 | `eth_balance{role="proposer"}` | < 0.1 ETH | P2 |
| 桥 mint 速率异常 | `rate(bridge_mint_total[10m])` | > 配置上限 | P0 |

### 7.2 Grafana 仪表盘

3 块大盘：
- **Chain Health**：L2 unsafe/safe/finalized head、出块时间分布、TPS、gas used
- **L1 Submission**：batcher posting delay、blob/calldata 成本、proposer 提交频率、各角色 ETH 余额
- **Bridge**：BSC 端 lock/unlock 数量与金额、L2 端 mint/burn、当前 in-flight 消息数、peg 偏差（应 ≈ 0）

OP Labs 提供官方 dashboard，导入即可：https://github.com/ethereum-optimism/optimism/tree/develop/op-monitorism

### 7.3 链下校验脚本（cron 跑）

每 5 分钟跑一次 `scripts/peg-check.sh`：

```bash
#!/usr/bin/env bash
LOCKED=$(cast call $BSC_TOKEN "balanceOf(address)(uint256)" $BSC_BRIDGE_SENDER --rpc-url $BSC_RPC)
ISSUED=$(cast call $L2_NATIVE_ASSET_LIQUIDITY "issuedSupply()(uint256)" --rpc-url $L2_RPC)
DELTA=$(echo "$ISSUED - $LOCKED" | bc)
if [[ ${DELTA#-} -gt 1000000000000000000 ]]; then
  curl -X POST $SLACK_WEBHOOK -d "{\"text\":\"PEG BREAK: locked=$LOCKED issued=$ISSUED delta=$DELTA\"}"
fi
```

**做完这章你应该看到**：故意停掉 op-batcher → 5 分钟内 Slack 弹"safe head 落后"告警；故意调一笔超额 mint → 立即弹"桥 mint 速率异常"告警。

---

## 8. 主网上线 checklist（24 项卡控）

Sepolia PoC 跑稳 ≥ 14 天且无 P0/P1 事故后才能开始走这一节。每一项必须有 owner 签字。

### 准备类
- [ ] 1. 主网 Ethereum RPC 用付费方案（Alchemy Growth+ / QuickNode Build+ / 自建 geth+lighthouse）
- [ ] 2. DEPLOYER 钱包持有 ≥ 1 ETH 主网
- [ ] 3. BATCHER / PROPOSER 钱包各持有 ≥ 2 ETH 主网，且接入自动续费脚本
- [ ] 4. 所有 5 个角色密钥迁移到 KMS / HSM
- [ ] 5. 所有 owner 角色（4 个 Safe 多签）已正式部署，签名人确认
- [ ] 6. BSC 主网上 MyToken 合约已部署、已 verify、已 audit
- [ ] 7. 桥合约（BridgeSender / BridgeReceiver）已 audit，audit 报告归档
- [ ] 8. LayerZero V2 正式 DVN 配置（3-of-5，含自营）已 confirm

### 部署类
- [ ] 9. `intent.toml` 中所有 owner 字段 = 多签地址，**不**是 EOA
- [ ] 10. `customGasToken.initialLiquidity` = BSC 上 MyToken total supply（必须等价）
- [ ] 11. `op-deployer apply` 部署 L1 合约成功，所有 proxy 指向正确实现
- [ ] 12. genesis.json / rollup.json 已生成并 hash 入仓
- [ ] 13. genesis 中 NativeAssetLiquidity 余额 = initialLiquidity（用 cast 验证）
- [ ] 14. L1 SystemConfig.isCustomGasToken() 返回 true
- [ ] 15. L2 L1Block.isCustomGasToken() 返回 true（出第一个块后验证）
- [ ] 16. OptimismPortal.depositTransaction{value: 1}() 必须 revert（ETH 不应能进 L2）

### 服务类
- [ ] 17. 4 台机器 + monitoring 全部就位，UFW + fail2ban 启用
- [ ] 18. op-geth peer 数 ≥ 1（即使是单 sequencer，建议留 1 个 RPC replica peer）
- [ ] 19. Blockscout indexer 追平到最新块，搜索能命中
- [ ] 20. 公开 RPC 限流规则生效（用 `wrk -t8 -c100 -d30s` 测应被限）

### 桥类
- [ ] 21. 端到端 mint 测试：BSC 转 1 MAN → L2 收到 1 MAN，时间 < 5 分钟
- [ ] 22. 端到端 burn 测试：L2 burn 1 MAN → BSC 收到 1 MAN，时间 < 10 分钟（含 LZ confirmations）
- [ ] 23. peg-check.sh cron 已部署并跑通

### 合规与公告
- [ ] 24. 上线公告 + 用户文档 + 风险提示 + 不可逆性说明已发布

---

## 9. 验收标准（38 条用例）

部署完成后逐条跑，全部 ✅ 才算交付。这些用例对应 §3-§7 各章末的"应该看到什么"，但更细。

### 9.1 链层验收（10 条）

| # | 用例 | 期望结果 |
|---|---|---|
| 1.1 | `cast block-number --rpc-url $L2_RPC` 重复 5 次，每次间隔 3 秒 | 数字单调递增，每次 +1 或 +2 |
| 1.2 | `cast block --rpc-url $L2_RPC latest` | timestamp 与系统时间差 < 5 秒 |
| 1.3 | `cast call $SystemConfigProxy "isCustomGasToken()(bool)" --rpc-url $L1_RPC` | `true` |
| 1.4 | `cast call 0x4200000000000000000000000000000000000015 "isCustomGasToken()(bool)" --rpc-url $L2_RPC` | `true` |
| 1.5 | `cast send $OptimismPortalProxy --value 1 --private-key $TEST_KEY --rpc-url $L1_RPC` | revert |
| 1.6 | `cast call 0x4200000000000000000000000000000000000020 "balance()(uint256)" --rpc-url $L2_RPC`（NativeAssetLiquidity） | = `intent.toml` 配置的 initialLiquidity |
| 1.7 | `cast call 0x4200000000000000000000000000000000000021 "owner()(address)" --rpc-url $L2_RPC`（LiquidityController） | = `liquidityControllerOwner` |
| 1.8 | `cast call 0x4200000000000000000000000000000000000021 "isAuthorizedMinter(address)(bool)" $BRIDGE_RECEIVER --rpc-url $L2_RPC` | `true` |
| 1.9 | 任意 EOA `cast balance $X --rpc-url $L2_RPC` | `0`（除非桥过 token） |
| 1.10 | sequencer 停 1 分钟再起 | 重启后能继续出块且不分叉 |

### 9.2 桥验收（10 条）

| # | 用例 | 期望 |
|---|---|---|
| 2.1 | BSC.MyToken.totalSupply() | = 配置上限 |
| 2.2 | 给 testUser 1 MAN，BSC.MyToken.transfer + BridgeSender.lock(1) | LayerZero 看到 message inflight |
| 2.3 | < 5 分钟后 cast balance testUser on L2 | = 1 ether |
| 2.4 | 用 testUser 在 L2 发普通转账（gas 用 MAN） | 成功，余额扣 gas |
| 2.5 | testUser 在 L2 调 BridgeReceiver.burn(0.5 ether) | L2 余额 -0.5 |
| 2.6 | < 10 分钟后 BSC.MyToken.balanceOf(testUser) | = 0.5 |
| 2.7 | peg 校验：`BSC.MyToken.balanceOf(BridgeSender)` | = `L2 native 流通总量` |
| 2.8 | 跑 1000 笔随机 lock/burn 后，peg 偏差 | = 0 |
| 2.9 | 故意 LZ 消息回放（重发已处理消息） | L2 端拒绝（idempotent） |
| 2.10 | 暂停桥（pause()） | lock/burn 全部 revert，恢复后正常 |

### 9.3 浏览器与钱包（8 条）

| # | 用例 | 期望 |
|---|---|---|
| 3.1 | 浏览器搜索 latest block 号 | 显示该区块详情 |
| 3.2 | 浏览器搜索 testUser 地址 | 显示 MAN 余额、tx 列表 |
| 3.3 | 浏览器交易详情 gas 列 | 显示 "X MAN"（不是 ETH） |
| 3.4 | 浏览器 Deposits 页 | 能看到桥的 deposit 事件 |
| 3.5 | 浏览器 Withdrawals 页 | 能看到 burn 事件 |
| 3.6 | MetaMask 干净安装，点 Add Network | 自动加 MAN 成功 |
| 3.7 | MetaMask 余额栏 | 显示 "0 MAN" |
| 3.8 | MetaMask 发交易 | gas estimate 显示 MAN |

### 9.4 监控告警（5 条）

| # | 用例 | 期望 |
|---|---|---|
| 4.1 | Grafana Chain Health 大盘 | 所有 panel 有数据 |
| 4.2 | 故意停 op-batcher 5 分钟 | Slack 收到 P1 告警 |
| 4.3 | 故意停 op-node 1 分钟 | Slack 收到 P0 告警 |
| 4.4 | 提走 PROPOSER 所有 ETH | Slack 收到 P2 告警 |
| 4.5 | 跑 peg-check.sh，故意 mock 偏差 | Slack 收到 PEG BREAK 告警 |

### 9.5 性能与安全（5 条）

| # | 用例 | 期望 |
|---|---|---|
| 5.1 | `wrk -t8 -c100 -d30s -s eth_call.lua https://rpc.man.xxx` | 平均 < 100ms p99 < 500ms |
| 5.2 | `wrk` 同上但 c1000 | Cloudflare 限流生效，超量返回 429 |
| 5.3 | 用 nmap 扫 node-1 | 仅 22 + 9222 开放 |
| 5.4 | 公开 RPC 调 `personal_listAccounts` | 返回 method not allowed |
| 5.5 | sequencer 私钥泄露应急演练 | 30 分钟内能用备份 sequencer key 切换并重启 |

---

## 10. 时间线与里程碑

```
W1  ┌──────────────┬──────────────────────────────────────────────┐
    │ §1 准备工作  │ §2 硬件采购 + 系统初始化                      │
    │              │ §3 B 阶段：本地 dev (3-5 天，10/10 验收)      │
W2  ├──────────────┴──────────────────────────────────────────────┤
    │ §3.5 C 阶段 Sepolia 部署 + §4 桥合约编码                      │
W3  ├──────────────────────────────────────────────────────────────┤
    │ §4 桥联调 + audit kickoff + §5 浏览器 + §6 钱包               │
W4  ├──────────────────────────────────────────────────────────────┤
    │ §7 监控 + Sepolia 长期运行 (≥14 天观察)                       │
W6  ├──────────────────────────────────────────────────────────────┤
    │ §8 主网 checklist 走完 + audit 报告归档                       │
W7  ├──────────────────────────────────────────────────────────────┤
    │ D 阶段：主网部署 + §9 验收 + 公告                             │
    └──────────────────────────────────────────────────────────────┘
```

总周期 **6-7 周**，关键路径在 audit（§4 桥合约 + §8 #7）。

> **注意**：B 阶段（本地 dev）放在 W1 内，是为了把所有工具链/版本/CGT 配置坑都先在 0 成本的环境里踩完。如果 B 跑不通，C 阶段会反复返工，整个工期会爆 1-2 周。

---

## 11. 故障排查表（最常见问题）

| 症状 | 可能原因 | 处理 |
|---|---|---|
| `op-deployer apply` 卡在 L1 部署 | L1 RPC 限流 | 换 Alchemy 付费 endpoint |
| `op-deployer apply --deployment-target genesis` 报 `unrecognized 4 byte signature` | op-deployer 版本与 op-contracts 版本不匹配 | 严格用 v0.6.0 + v6.0.0 组合 |
| genesis 后 L1Block.isCustomGasToken() = false | intent.toml 没填 `[chains.customGasToken]` 块 | 改 intent，重跑 genesis |
| op-node 起不来：`incompatible chain config` | genesis.json / rollup.json 与 op-geth datadir 已初始化的链不一致 | `make clean && make all-sepolia` 重来 |
| op-batcher 一直报 "nonce too low" | 同一 batcher key 在另一台机器上也跑着 | 确保 key 唯一在跑，必要时 cast reset nonce |
| 桥 mint 上去钱包看不到余额 | RPC 节点没追上 / MetaMask 没刷新 | 等 5 秒、换钱包账号再切回来 |
| Blockscout 一直 "indexing" | Etherbase 0x0 没数据，indexer 等不到 | 等 op-node 出 30+ 个块后再起 indexer |
| 跨链消息卡住 | LayerZero DVN 没确认 | https://layerzeroscan.com 查具体 tx 状态 |

---

## 12. 参考链接（一键收藏）

- OP Stack CGT v2 概览：https://docs.optimism.io/op-stack/features/custom-gas-token
- CGT v2 部署指南：https://docs.optimism.io/chain-operators/guides/features/custom-gas-token-guide
- op-deployer 文档：https://docs.optimism.io/chain-operators/tools/op-deployer/overview
- op-deployer init：https://docs.optimism.io/chain-operators/tools/op-deployer/usage/init
- op-deployer apply：https://docs.optimism.io/chain-operators/tools/op-deployer/usage/apply
- intent.toml schema：https://pkg.go.dev/github.com/ethereum-optimism/optimism/op-deployer/pkg/deployer/state
- Optimism U18 治理提案：https://vote.optimism.io/proposals/77621298185123846119233191553645120427678039792258174752758738057653049982021
- Network upgrades 时间表：https://docs.optimism.io/op-stack/protocol/network-upgrades
- Blockscout for OP Stack：https://docs.blockscout.com/setup/deployment/manual-deployment-guide
- LayerZero V2 文档：https://docs.layerzero.network/v2
- chainlist.org 提交：https://github.com/ethereum-lists/chains
- op-monitorism 官方监控：https://github.com/ethereum-optimism/optimism/tree/develop/op-monitorism
