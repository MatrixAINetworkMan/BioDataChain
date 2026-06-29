# 机器 #6：L2 只读副本 #2

> 角色：与 #5 完全相同的**只读 RPC 副本**（op-geth + op-node verifier）。第二台用于读流量负载均衡与冗余（一台维护/宕机时另一台仍服务）。

---

## 1. 部署

**完全照搬 [05-L2-replica-1.md](05-L2-replica-1.md)**，仅以下不同：

- 本机 `PUBLIC_HOST` 用本机地址；
- p2p `--p2p.static` 同样指向 #3 主 sequencer 的 enode（也可同时 peer #5，增强 gossip）；
- 同样**复用 #3 的 `workdir/shared`，不重新 deploy**。

```bash
cd /data/code/mychain/dev
tar xzf shared.tgz
cp .env.example .env && vim .env   # 同 #5，L1 指 #1，chainId/参数与 #3 一致
docker compose --env-file .env up -d l1-proxy op-geth op-node   # 仅 verifier + read RPC
```

## 2. 验收

同 #5：syncStatus 追平、chainId=`0x2ae54`、与主同高度块 hash 一致、历史 tx 可查。

## 3. 与 #5 的关系（高可用读层）

- #8 LB 把公网 read RPC 在 **#5 + #6** 之间轮询/健康检查路由；
- 任一副本下线，LB 自动摘除，读服务不中断；
- Blockscout indexer 建议指向**一台固定副本**（避免索引时在副本间跳导致 reorg 抖动），另一台纯给公网读。

## 4. 横向扩展

读 QPS 不够时，照本文再加 #7、#8… 副本，挂进 LB 即可线性扩。副本是无状态可丢弃单元。
