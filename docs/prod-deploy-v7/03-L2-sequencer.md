# 机器 #3：L2 主 sequencer（Flashblocks 全栈 + proxy）

> 角色：唯一的出块节点 + dApp 入口。跑 **op-geth + op-node + op-batcher + op-rbuilder + rollup-boost + bundle-proxy + l1-proxy**。
> **这台是唯一执行 deploy（部署 L1 合约 + 生成 L2 genesis）的机器。**
> chainId 175700，MAN 即 Gas。代码：`dev/`。

---

## ⚠️ 0. 1000+ TPS 的关键：必须走 proxy / Flashblocks 启动

**纯 `make dev-up`（op-geth 单 sequencer）只有 ~115-180 TPS，达不到 1000+。**
1000+ TPS 必须用 **`make dev-up-flashblocks`**，它会把 **op-rbuilder（真正出块的 builder）+ rollup-boost + bundle-proxy** 一起拉起。实测 op-rbuilder 路径单机 798 TPS（i4i.2xlarge）、100M block gas 下可上 1500-2000 TPS。

两个 proxy 都必须在启动时启用：

- **l1-proxy**：拦截 `eth_blobBaseFee` 返回 `0x1`（自建 L1 无 Cancun/blob，否则 op-batcher 卡死、safe 永不推进）。由 `docker-compose.external-l1.yml` 引入，`.env` 里 `L1_RPC_URL_INTERNAL=http://l1-proxy:8546` 自动激活。
- **bundle-proxy**：dApp 唯一入口（:9560），带 fail-fast 限流/熔断/降级，转发到 op-rbuilder。由 `docker-compose.flashblocks.yml` 引入。

**记牢：钱包/dApp/压测流量都打 `bundle-proxy:9560`，不是 op-geth。**

---

## 1. 硬件

| 项 | 推荐（留 100M gas/1000+ TPS 余量）| 最低（=i4i.2xlarge 实测档）|
|---|---|---|
| CPU | 16 vCPU（高频 3.5GHz+）| 8 vCPU |
| 内存 | 128 GB | 64 GB |
| 磁盘 | **本地 NVMe 2–4 TB** | 1.9 TB NVMe |
| 网络 | 10 Gbps，与 L1 机低延迟 | — |

## 2. 端口 / 防火墙

| 端口 | 用途 | 范围 |
|---|---|---|
| 22 | SSH | 白名单 |
| 9560 | **bundle-proxy（dApp 入口）** | 经 #8 LB 对公网；直连仅内网 |
| 9561 | bundle-proxy metrics | 仅内网（监控抓）|
| 9545/9546 | op-geth RPC/WS（fallback/调试）| 仅内网 |
| 9547 | op-node RPC | 仅内网 |
| 9550/9555 | op-rbuilder / rollup-boost | 仅内网 |
| 30303 | L2 p2p（给热备/副本）| L2 内网 |

## 3. 部署步骤

```bash
cd /data/code/mychain/dev
cp .env.example .env
vim .env
```

`.env` 关键项（生产）：

```bash
PUBLIC_HOST=<本机公网IP或域名>

# —— external-L1：指向 #1 L1 主节点，并启用 l1-proxy ——
COMPOSE_FILE=docker-compose.yml:docker-compose.external-l1.yml
L1_CHAIN_ID=901
L1_RPC_URL_INTERNAL=http://l1-proxy:8546
L1_RPC_URL_EXTERNAL=http://<L1主内网IP>:8545
L1_PROXY_UPSTREAM=http://<L1主内网IP>:8545

# —— 链参数（改了必须重建链，上线前定死）——
L2_BLOCK_TIME=3
L2_GAS_LIMIT=100000000           # 1000+ TPS 必需
NATIVE_TOKEN_SYMBOL=MAN
NATIVE_TOKEN_NAME="Matrix AI Network"
BATCHER_DA_TYPE=calldata          # 自建 L1 无 blob

# —— 生产密钥：全部换成 KMS/HSM 真实 key，禁用 anvil 测试 key ——
DEPLOYER_ADDRESS=...  DEPLOYER_PRIVATE_KEY=...   # 建议走远程签名，不落明文
BATCHER_ADDRESS=...   BATCHER_PRIVATE_KEY=...
SEQUENCER_ADDRESS=... SEQUENCER_PRIVATE_KEY=...
PROPOSER_ADDRESS=...  PROPOSER_PRIVATE_KEY=...
OWNER_MULTISIG=<Safe多签地址>
FEE_RECIPIENT=<金库地址>

# txpool（生产 baseline fail-fast；想要纯容量见 STRESS_TEST_REPORT_V7）
OP_GETH_TXPOOL_GLOBALSLOTS=500
OP_GETH_TXPOOL_ACCOUNTSLOTS=8
OP_GETH_CACHE_MB=8192
```

> `dev/.env.flashblocks`（已在仓库，不含密钥）会覆盖 `L2_CHAIN_ID=175700`、`OP_NODE_L2_ENGINE_URL=http://rollup-boost:8081` 及 proxy 端口。**确认它存在**：`test -f .env.flashblocks || git checkout dev/.env.flashblocks`。

先确保 #1 L1 已出块、给角色账号转好 L1 gas（见文档 01 §7），然后**一键起全栈**：

```bash
make dev-up-flashblocks
```

这条会按正确顺序执行：渲染 intent → 部署 L1 合约（op-deployer）→ 生成 L2 genesis/rollup.json → init op-geth → 起 op-geth → 起 op-rbuilder+rollup-boost+bundle-proxy → 等 rollup-boost 就绪 → 起 op-node+op-batcher。

## 4. 验收

```bash
make flashblocks-smoke      # 9 项端到端冒烟（容器健康+RPC+metrics+链可达）
make flashblocks-info       # 打印 bundle-proxy 入口等端点
make flashblocks-status

# proxy 启用确认
curl -s localhost:9560/healthz                      # bundle-proxy 200
docker compose ps l1-proxy                           # healthy
docker exec l1-proxy python3 -c 'import urllib.request as u,json;print(json.loads(u.urlopen(u.Request("http://127.0.0.1:8546",data=b"{\"jsonrpc\":\"2.0\",\"method\":\"eth_blobBaseFee\",\"params\":[],\"id\":1}",headers={"Content-Type":"application/json"})).read())["result"])'  # 必须 0x1

# 链在出块、chainId 对
curl -s -X POST localhost:9547 -d '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' -H content-type:application/json | jq .result
curl -s -X POST localhost:9550 -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' -H content-type:application/json   # 0x2ae54
```

- safe head 在涨（batcher 经 l1-proxy 正常 post）；
- `admin_sequencerActive` = true；
- 无 op-node 红线（`L1 chain has reset` / `mismatch` / `rewind`）。

## 5. 交接给热备/副本（关键，别在它们上 deploy）

```bash
# 把 genesis/rollup/jwt 拷给 #4/#5/#6 复用（不可重新 deploy，否则开新链）
tar czf shared.tgz workdir/shared .env.flashblocks
# 用 scp/rsync 发给 #4/#5/#6；.env 各机单独写（密钥/角色不同）
# 取本机 op-node enode 给 verifier 做 p2p static peer：
docker logs mychain-op-node 2>&1 | grep -i enode | tail -1
```

## 6. 运维与压测

```bash
make flashblocks-logs                 # 跟 v7 容器日志
make bot-token-chain-tps N=30         # 看链上真实 TPS
make bot-token-mempool                # mempool 大小
make flashblocks-recover              # op-node 卡 Waiting 时一键恢复
```

- 性能/容量模式细节见 `docs/STRESS_TEST_REPORT_V7.md`。
- 数据卷 `dev_opgeth-data` / `dev_rbuilder-data` 定期快照。
