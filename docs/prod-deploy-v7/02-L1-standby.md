# 机器 #2：L1 热备节点

> 角色：L1 **全节点（不出块）**，从主节点 p2p 同步全部 L1 数据。主节点宕机时，作为数据冗余与快速恢复来源；必要时切换为出块验证者。
> 代码：同 `dev/l1/`，但**不持有 validator 签名权**（除非升格）。

---

## 1. 硬件

同 #1 L1 主节点（8 vCPU / 32 GB / NVMe 2–4 TB）。热备规格不应低于主，以便随时顶上。

## 2. 端口 / 防火墙

| 端口 | 用途 | 范围 |
|---|---|---|
| 22 | SSH | 运维白名单 |
| 30303 | p2p（连主节点）| L1 内网 |
| 8545/8546 | RPC（可选，给监控/额外副本）| 仅内网 |

## 3. 部署步骤（作为同链全节点同步）

```bash
cd /data/code/mychain/dev/l1
cp .env.example .env
vim .env
#   PUBLIC_HOST=<本机内网IP>
#   CHAIN_ID=901（必须与主一致）
#   不要重新 make init 生成新 genesis —— 必须用与主【完全相同】的 genesis
```

**关键：genesis 必须与主一致**，否则两条链对不上。两种做法选一：

- **做法 A（推荐，拷主的 genesis）**：从 #1 拷 `dev/l1/` 下的 `genesis.json` / 配置到本机相同路径，再 `geth init` + `make up`（不跑 `make init` 的 keygen 部分）。
- **做法 B（同 .env 同参数渲染）**：保证 `.env` 里影响 genesis 的字段（CHAIN_ID、PERIOD、预分配、validator 集 extraData）与主**逐字一致**，再 `make init`。任何差异都会导致 genesis hash 不同。

配置静态连主节点 p2p（加 bootnode/static-node 指向 #1 的 enode）：

```bash
# 取主节点 enode（在 #1 上执行）
docker exec mychain-l1-geth geth attach --exec 'admin.nodeInfo.enode' /data/geth.ipc
# 在本机把它加入 static-nodes（或 .env 的 BOOTNODES），然后 make up
make up
make status   # Block# 应快速追平主节点当前高度
```

## 4. 验收

- 本机 `make status` 的 Block# **追平并跟随**主节点（差几个块属正常）；
- genesis hash 与主**完全一致**（不一致说明 genesis 不同，必须重来）：
  ```bash
  docker exec mychain-l1-geth geth attach --exec 'eth.getBlock(0).hash' /data/geth.ipc
  ```

## 5. 故障切换（主节点宕机时升格为出块者）

> Clique 单 validator 架构下，热备默认不出块。主挂后让热备出块需要 validator 签名权。

- **若采用「同一把 validator key」模型**：把主的 validator keystore + password 安全地配到热备（同一地址），停掉主（确保不会双签），在热备 `.env` 开启 `--mine`/unlock 后 `make restart`。**务必确认主已彻底停**，避免两个节点用同一 key 双签导致分叉。
- 切换后通知 L2 机：若 L2 的 `L1_PROXY_UPSTREAM` 指的是主 IP，需改指热备 IP 并 `make flashblocks-restart-proxy`（或重启 l1-proxy）。

## 6. 运维

- 定期校验热备与主的 Block# 差值（监控告警，差值持续拉大=同步异常）。
- 冷备策略同 #1。
