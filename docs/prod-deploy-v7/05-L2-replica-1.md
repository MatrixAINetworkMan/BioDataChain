# 机器 #5：L2 只读副本 #1

> 角色：**op-geth full node + op-node(verifier)**，从主 sequencer p2p / 从 L1 派生同步，对外提供**只读 RPC**（公网 read、喂 Blockscout 索引）。不出块、不发 batch、不需要 Flashblocks 三件套。
> 这是 L2 读流量的**横向扩展**单元：QPS 不够就再加副本（#6、#7…）挂到 LB 后面。

---

## 1. 硬件

| 项 | 推荐 | 最低 |
|---|---|---|
| CPU | 8 vCPU | 4 vCPU |
| 内存 | 32 GB | 16 GB |
| 磁盘 | 本地 NVMe 2 TB | 1 TB |

> 副本不出块，负载主要是 RPC 查询 + 同步,比 sequencer 轻；但 state DB 仍走 NVMe。

## 2. 端口 / 防火墙

| 端口 | 用途 | 范围 |
|---|---|---|
| 22 | SSH | 白名单 |
| 9545/9546 | op-geth read RPC/WS | 经 #8 LB 对公网；或仅内网给浏览器 |
| 9547 | op-node RPC | 仅内网 |
| 30303 | L2 p2p（连主 sequencer）| L2 内网 |

## 3. 部署步骤

```bash
cd /data/code/mychain/dev
# 1) 复用 #3 拷来的 shared（不可重新 deploy）
tar xzf shared.tgz                 # workdir/shared + .env.flashblocks
# 2) 写 .env：L1 指向 #1，chainId/L2_BLOCK_TIME/L2_GAS_LIMIT 与 #3 一致
cp .env.example .env && vim .env
#    COMPOSE_FILE=docker-compose.yml:docker-compose.external-l1.yml
#    L1_RPC_URL_INTERNAL=http://l1-proxy:8546
#    L1_RPC_URL_EXTERNAL / L1_PROXY_UPSTREAM = http://<L1主内网IP>:8545
#    密钥：副本不出块/不发 batch，BATCHER/SEQUENCER key 可留占位，不会用到
```

**只起 op-geth + op-node(verifier)，不起 op-batcher / op-rbuilder / rollup-boost / bundle-proxy：**

```bash
# op-node 以 verifier 起（去掉 --sequencer.enabled），p2p 连主 sequencer
#   在本机 docker-compose 覆盖 op-node command：加 --p2p.static=<#3 op-node enode>，不开 sequencer
# 用拷来的 genesis init op-geth（不要 op-deployer / deploy-genesis）：
docker compose --env-file .env up -d l1-proxy op-geth op-node
#   首次需先 init-geth（用拷来的 genesis.json，见 MACHINE_MIGRATION_RUNBOOK_V7 §5）
```

> 详细的「带配置不重新 deploy、让 op-node 从 L1 重放追平」流程见 `docs/MACHINE_MIGRATION_RUNBOOK_V7.md` §5（纯 L1 重建）。副本就是一个 verifier。

## 4. 验收

```bash
# 同步追平 + chainId 一致
curl -s -X POST localhost:9547 -d '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' -H content-type:application/json | jq '.result|{unsafe:.unsafe_l2.number,safe:.safe_l2.number}'
curl -s -X POST localhost:9545 -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' -H content-type:application/json   # 0x2ae54
# 与主 sequencer 同高度块 hash 一致（确认在同一条链上）
curl -s -X POST localhost:9545 -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' -H content-type:application/json | jq '.result|{number,hash}'
```

- head 跟随主、不归零；
- genesis hash / chainId 与主一致；
- 历史 tx 可查（`eth_getTransactionReceipt`）。

## 5. 运维

- 这是**无状态可丢弃**单元：坏了直接重建一台再同步即可，不影响链。
- 监控同步 lag（与主 head 差值）；lag 持续增大 → 检查 p2p / L1 连接。
- 读流量由 #8 LB 在多副本间负载均衡;扩容 = 照本文再开一台 #6/#7。
