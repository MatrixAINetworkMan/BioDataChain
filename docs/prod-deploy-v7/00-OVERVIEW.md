# MAN 正式链部署总览（v7 / 8 台机器）

> 架构：自建 **L1（geth Clique，chainId 901）** + **OP Stack L2（chainId 175700，Flashblocks）**。
> 原生币 MAN 即 Gas，DA 投自家 L1（零外部 ETH/BNB 成本）。
> **高 TPS 关键：L2 必须走 Flashblocks/bundle-proxy 路径启动**（见文档 03），纯 op-geth 单 sequencer 仅 ~115-180 TPS，1000+ TPS 必须 `make dev-up-flashblocks`。

---

## 0. 8 台机器与文档对应

| # | 机器 | 角色 | 文档 |
|---|---|---|---|
| 1 | L1 主节点 | geth Clique 出块验证者 + L1 DA 层 | [01-L1-primary.md](01-L1-primary.md) |
| 2 | L1 热备 | L1 全节点（不出块），主挂时顶上 | [02-L1-standby.md](02-L1-standby.md) |
| 3 | **L2 主 sequencer** | op-rbuilder+geth+node+batcher+rollup-boost+**bundle-proxy**+l1-proxy（出块 + dApp 入口）| [03-L2-sequencer.md](03-L2-sequencer.md) |
| 4 | L2 热备 sequencer | verifier 跟链，故障时 promote 成 sequencer | [04-L2-standby.md](04-L2-standby.md) |
| 5 | L2 只读副本 #1 | op-geth+op-node(verifier)，公网 read RPC | [05-L2-replica-1.md](05-L2-replica-1.md) |
| 6 | L2 只读副本 #2 | 同上，横向扩 | [06-L2-replica-2.md](06-L2-replica-2.md) |
| 7 | Blockscout | L1+L2 区块浏览器（Postgres）| [07-blockscout.md](07-blockscout.md) |
| 8 | LB/网关 + 监控 | nginx/TLS + Prometheus/Grafana | [08-lb-monitoring.md](08-lb-monitoring.md) |

## 1. 拓扑

```
                 ┌─────────────── L1 层（自建，chainId 901）──────────────┐
   #1 L1 主 ◀───▶ #2 L1 热备   （geth Clique，2s 出块，互为 p2p peer）
                 └────────────────────────▲──────────────────────────────┘
                          batch/DA(MAN付费) │ derive
   ┌──────────────────────── L2 层（OP Stack，chainId 175700）───────────────────────┐
   │  #3 主 sequencer ──p2p──▶ #4 热备(verifier)                                       │
   │       │                    #5 副本   #6 副本   （op-geth follower + read RPC）     │
   └───────┼────────────────────────┬─────────────┬───────────────────────────────────┘
           │ bundle-proxy:9560       │ read RPC    │ read RPC
           ▼                          ▼            ▼
        #8 LB / nginx(TLS) ◀── 公网 dApp / 钱包          #7 Blockscout(indexer 指副本)
           │
           └── #8 Prometheus/Grafana 抓各机 metrics
```

## 2. 部署顺序（严格按序）

1. **#1 L1 主** → 出块正常，记下内网 IP（后面 L2 要用）。
2. **#2 L1 热备** → 同步追平主。
3. **#3 L2 主 sequencer** → 指向 L1 主 IP，**一次性**部署 L1 合约 + L2 genesis，`make dev-up-flashblocks` 起全栈。**这台是唯一执行 deploy 的机器。**
4. 从 #3 拷出 `dev/workdir/shared/`（genesis.json / rollup.json / jwt.txt）→ #4/#5/#6 复用，**绝不能在这些机器上重新 deploy**（否则 genesis hash 变 = 开新链）。
5. **#4 L2 热备**、**#5 #6 副本** → 用拷来的 shared 起 verifier。
6. **#7 Blockscout** → indexer 指向某台副本的 RPC。
7. **#8 LB + 监控** → nginx 反代 + 抓 metrics。

## 3. 所有机器的共享前置（每台都要做）

```bash
# Ubuntu 22.04+
sudo apt update && sudo apt install -y git make jq gettext-base curl python3

# Docker CE（官方源，别装 docker.io）
if ! (command -v docker >/dev/null && docker compose version >/dev/null 2>&1); then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo usermod -aG docker $USER && newgrp docker

# 本地 NVMe 挂到 /data（出块/状态盘，绝不用网络盘）
#   按各机 lsblk 实际盘符 mkfs + mount 到 /data，写进 /etc/fstab

# 拉代码
sudo mkdir -p /data/code && sudo chown $USER:$USER /data/code
cd /data/code && git clone <REPO_URL> mychain && cd mychain
git checkout feat/high-tps-flashblocks
```

## 4. 生产安全铁律（贯穿所有文档）

- **私钥**：`.env.example` 里的是 anvil 公开测试 key，**生产必须全部换成 KMS/HSM 托管的真实 key**（DEPLOYER / BATCHER / SEQUENCER / PROPOSER），owner 角色用 Safe 多签。
- **`.env` 不入仓**（含密钥）。`.env.flashblocks` 已在仓库（不含密钥）。
- **L2 genesis/合约只在 #3 部署一次**，其余机器复用 `workdir/shared/`。
- **改 `L2_BLOCK_TIME` / `L2_GAS_LIMIT` / chainId 必须重建链**（进 genesis），上线前定死。
- 数据卷上线后做**定期快照**（既是灾备，也是回滚/迁移的本钱）。
