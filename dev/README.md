# MAN L2 — dev 环境（B 阶段）

> **目标**：在一台 AWS 服务器上，零成本拉起一条 **OP Stack v6.0.0 + CGT v2** 链，把 `MAN` 当原生 gas，跑通核心流程，作为 Sepolia 阶段的预演。
>
> **规模**：单机即可，不依赖外部 L1。
>
> **耗时**：首次部署约 10–15 分钟（含拉镜像）。

---

## 0. 拓扑

```
┌──────── docker network: mychain-dev ────────┐
│                                             │
│  anvil (L1, 假以太坊)                        │
│    └─ chain ID 901, 无限 ETH, 2s 出块         │
│                                             │
│  op-deployer (一次性, v0.6.0)                 │
│    └─ 用 intent.toml 部署 CGT v2 全套合约      │
│                                             │
│  op-geth ←→ op-node (sequencer)             │
│      ↑                                       │
│  op-batcher (写 batch 回 anvil)              │
│                                             │
│  op-proposer (可选，profile=proposer)        │
│    └─ dev 阶段不需要，到 Sepolia 再开         │
│                                             │
└─────────────────────────────────────────────┘

       ↑ 主链
       ↓ 浏览器（独立 stack，挂同一个 docker network）

┌──────── dev/blockscout/docker-compose.yml ────┐
│  postgres + redis                             │
│  blockscout-backend (Optimism flavor)         │
│  blockscout-frontend                          │
│  smart-contract-verifier + sig-provider       │
└───────────────────────────────────────────────┘
```

---

## 1. 前置条件（AWS 机器上一次性配置）

| 项目 | 推荐 |
|---|---|
| OS | Ubuntu 22.04 / 24.04 |
| 规格 | 4 vCPU / 16 GB RAM / 200 GB SSD（dev 阶段够用）|
| 用户 | `work`（在 `docker` + `sudo` 组里）|
| Docker | ≥ 24.x，含 compose v2.x |
| 端口 | 22, 8545, 9545, 9546, 9547, 4000, 4001（按需开 22 限本地 IP）|

> 已经在前面装好 docker 和 kurtosis。这里不用 kurtosis，但 docker 必须 OK。
> 如果 `docker compose version` 显示 `v5.x`，先跑一次 `docker compose -f dev/docker-compose.yml config` 看是否能解析；不行的话装一下官方 v2：`sudo apt install docker-compose-plugin`。

---

## 2. 把代码推到 AWS

在你本地：

```bash
cd /Users/opts/projects/mychain
git add dev/
git commit -m "dev: bootstrap OP Stack v6.0.0 + CGT v2 local devnet"
git push
```

在 AWS（用 `work` 用户，**不是 root**）：

```bash
# 选一个你喜欢的目录，例如 ~/mychain 或 /data/code/mychain
# 实际服务器是 /data/code/mychain/，下文命令里出现 PROJECT_ROOT 时替换成你这台机器的真实路径
git clone <你的仓库 URL> /data/code/mychain
cd /data/code/mychain/dev
```

---

## 3. 配置 .env

```bash
cd /data/code/mychain/dev
cp .env.example .env

# 改 PUBLIC_HOST：填这台 AWS 的外网 IP（团队从外面访问时用的就是它）
sed -i 's/^PUBLIC_HOST=.*/PUBLIC_HOST=18.123.45.67/' .env   # 改成你的 IP

# 其他默认值都能用（dev 阶段密钥都是 anvil 公开 key）
```

---

## 4. 一键拉起

```bash
make pull         # 预先拉 5 个镜像，约 5 分钟（首次）
make dev-up       # 一键完整启动
```

`make dev-up` 内部会顺序跑：

1. `check-env`  — 校验 .env 和工具
2. `render-intent` — 把 `intent.toml.example` envsubst 成 `workdir/intent.toml`
3. `l1-up` — 启动 anvil 并等 healthy
4. `deploy-l1` — `op-deployer apply` 部署 L1 合约（CGT v2 全套）
5. `deploy-genesis` — 生成 `genesis.json` + `rollup.json` + `jwt.txt`
6. `init-geth` — 用 genesis 初始化 op-geth datadir
7. `l2-up` — 启动 op-geth + op-node + op-batcher + op-proposer
8. `status` + `info` — 显示状态和团队访问地址

如果中途某步挂了，单独跑那步就行：

```bash
make deploy-l1
make logs-op-deployer
```

---

## 5. 验证（关键！）

### 5.1 端到端健康

```bash
make healthcheck
```

应该看到 6 项全部 ✅。

### 5.2 CGT v2 验收

```bash
make verify-cgt
```

跑 10 项核心用例：原生币 symbol、`L1Block.isCustomGasToken()`、`NativeAssetLiquidity` 余额、`LiquidityController` 部署、转账 / gas 计价、零余额拒绝、batcher 活跃、safe head 进度。

**这一步如果 10 条全过，就说明 CGT v2 在你的环境里跑通了。** 后面切 Sepolia 只是把 `intent.toml` 的 `l1ChainID` / RPC / private key 换一下，行为完全一样。

### 5.3 浏览器（可选，Blockscout 完整版）

```bash
make pull-blockscout    # 首次运行，约 2GB 下载
make blockscout-up      # 拉起 6 个容器，~2GB RAM
make blockscout-logs    # 等 backend 出现 "started Phoenix endpoint" 即可访问
```

约 1–2 分钟首次启动（要建 ~150 张表 + 索引创世块），然后访问 `http://<PUBLIC_HOST>:4000`。

**注意 AWS 安全组要同时开 4000 + 4001**：
- 4000 = Blockscout 前端（浏览器入口）
- 4001 = Blockscout 后端 API（前端 ajax 走它，没开会一直转圈圈）

支持的功能：合约验证、ERC20/721/1155 token list、L1↔L2 deposit/withdrawal cross-chain、address QR、内部交易调用栈、事件 ABI 自动解析。

```bash
make blockscout-status      # 6 容器状态
make blockscout-logs        # tail backend + frontend
make blockscout-logs-backend  # 只看 backend
make blockscout-down        # 停（保留 DB 数据，下次起来不用重新索引）
make blockscout-clean       # 删掉所有 blockscout 数据（不影响主链）
```

> Blockscout 跟主链是 **完全独立的 docker-compose**（在 `dev/blockscout/`），所以
> `make dev-down` / `make dev-clean` 都不会动它。
> 反过来 `make blockscout-down` 也不会动主链。
> 一次性拆全部：`make dev-down-all` / `make dev-clean-all`。

### 5.4 钱包接入

`make info` 会打印 MetaMask / Rabby 的添加参数，复制粘贴即可。

---

## 6. 常用命令

```bash
make help           # 看完整命令清单
make status         # docker 服务状态
make info           # 团队访问 URL
make logs           # tail 全部日志
make logs-op-node   # 单独看某个服务
make verify-cgt     # CGT 验收
make dev-down       # 停主链（不动 blockscout）
make dev-clean      # 全删主链 + workdir（不动 blockscout）
make dev-down-all   # 同时停主链 + blockscout
make dev-clean-all  # 同时清主链 + blockscout DB（不可恢复）
make dev-restart    # = dev-clean + dev-up
make blockscout-up  # 启 Blockscout（6 容器，~2GB RAM）
make blockscout-down  # 停 Blockscout（保留 DB）
make cast-l2        # 进 cast shell 连 L2
```

---

## 7. 常见坑

| 现象 | 原因 | 解决 |
|---|---|---|
| `permission denied /var/run/docker.sock` | `work` 不在 `docker` 组 / 没 relogin | `sudo -iu work` 或重新 SSH |
| `op-deployer` 拉不到 `tag://op-contracts/v6.0.0` | 网络受限 | `make pull` 先把所有镜像拉好；或挂代理给 docker daemon |
| `op-batcher` 报 `4844 not supported` | anvil 不支持 blob | `.env` 里 `BATCHER_DA_TYPE=calldata`（已是默认）|
| `verify-cgt` 第 2 项失败 | op-contracts 版本不匹配 | 检查 `OP_*_IMAGE` 三件套的版本是否对应 v6.0.0 |
| L2 不出块 | op-node 起不来 | `make logs-op-node`，多半是 jwt.txt 或 rollup.json 缺失 |
| `make dev-up` 卡在 `deploy-l1` | anvil 还没准备好 | 等 5s 重试；或 `docker logs mychain-anvil` 看 |

---

## 8. 切换到 Sepolia（C 阶段）时改什么

> 只列差异；其他文件不动。

`.env` 改 4 行：

```diff
-L1_CHAIN_ID=901
-L1_RPC_URL_INTERNAL=http://anvil:8545
-L1_RPC_URL_EXTERNAL=http://anvil:8545
-BATCHER_DA_TYPE=calldata
+L1_CHAIN_ID=11155111
+L1_RPC_URL_INTERNAL=https://your-sepolia-rpc-provider.example/your-key
+L1_RPC_URL_EXTERNAL=https://your-sepolia-rpc-provider.example/your-key
+BATCHER_DA_TYPE=auto
```

`.env` 替换 5 个角色的真实私钥（**不要再用 anvil 公开 key**）：
`DEPLOYER_PRIVATE_KEY` / `BATCHER_PRIVATE_KEY` / `PROPOSER_PRIVATE_KEY` / `CHALLENGER_PRIVATE_KEY` / `SEQUENCER_PRIVATE_KEY`，并把 `OWNER_MULTISIG` 换成 Safe。

`docker-compose.yml` 移除 `anvil` 服务（或保留，无害，但不再启动），其他服务改 `depends_on` 不依赖 anvil。

然后：

```bash
make dev-clean
make dev-up
```

—— 跟 dev 阶段是同一个流程，但这次跑在 Sepolia 上，需要 ~1 Sepolia ETH 作为部署 gas。

---

## 9. 下一步

dev 跑通后，下面几件事可以并行：

- 写 BSC 端 ERC-20 代币 + LayerZero OApp（`contracts/bsc/`）
- 写 L2 端的 `LiquidityController` 调用桥（`contracts/l2/`）
- 跑端到端"BSC -> L2 桥入 + L2 用 MAN 付 gas + L2 -> BSC 桥出" 的 e2e 用例
- 准备 Sepolia 阶段的 5 个角色私钥 + Safe 多签 + Sepolia ETH

详见上层文档 `docs/PLAN_OPSTACK_CGTV2.md`。
