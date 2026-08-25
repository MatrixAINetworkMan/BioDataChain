# Matrix L2 节点部署包

面向交易所的独立 L2 验证节点部署包。节点**只验证不出块**，可本地查询链上数据，并可将交易转发上链（发交易）。

- 读：本地节点直接查询，不依赖第三方
- 写：已签名交易经配置的转发端点提交上链
- 前置依赖：Linux（推荐 Ubuntu 22.04）、Docker + Docker Compose v2

---

## 一、目录结构

```
exchange/
├── docker-compose.exchange.yml   # 服务定义（自包含，无需其他文件）
├── .env.example                  # 环境变量模板（复制为 .env）
├── scripts/
│   └── op-geth-entrypoint.sh     # 启动时自动初始化数据目录（幂等）
├── l1-proxy/
│   └── proxy.py                  # L1 连接代理（自动处理协议兼容）
└── workdir/shared/               # 项目方提供（genesis / rollup / jwt 等）
    ├── genesis.json
    ├── rollup.json
    ├── l1-chain-config.json
    └── jwt.txt
```

> `workdir/shared/` 由项目方在交付时提供，**请勿修改其中任何文件**。

---

## 二、部署（环境依赖安装好后，直接从第3步启动）

### 1. 准备环境变量（文件已经配置好，本步骤可以跳过）

```bash
cp .env.example .env
vim .env
```

需要填写的项（其余保持默认）：

| 变量 | 说明 | 来源 |
|------|------|------|
| `L1_PROXY_UPSTREAM` | L1 结算链 RPC 地址（节点同步必需） | 项目方提供 |
| `L2_SEQUENCER_HTTP` | 交易转发端点（发交易必需） | 项目方提供 |
| `L2_SEQUENCER_ENODE` | P2P 地址（可选，加速接收新区块） | 项目方提供，可留空 |
| `BIND_HOST` | 节点监听地址；仅本机用 `127.0.0.1`，对外提供 RPC 用 `0.0.0.0` | 自行决定 |

### 2. 放置 shared 文件（文件已经放置好，本步骤可以跳过）

将项目方提供的 `genesis.json`、`rollup.json`、`l1-chain-config.json`、`jwt.txt` 放入 `workdir/shared/`。

### 3. 启动

```bash
docker compose -f docker-compose.exchange.yml up -d
```

首次启动会自动初始化数据目录并开始同步，无需额外步骤。

### 4. 确认同步完成

```bash
# 查看三头块高（unsafe / safe / finalized）
curl -s -X POST http://127.0.0.1:9547 -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"optimism_syncStatus","params":[]}' | jq .result
```

`safe_l2.number` 持续增长并接近链头即同步完成。从创世同步耗时取决于当前链高度。

---

## 三、维护命令

```bash
# 查看容器状态
docker compose -f docker-compose.exchange.yml ps

# 查看节点日志（同步进度 / 错误）
docker compose -f docker-compose.exchange.yml logs -f --tail=100 op-node
docker compose -f docker-compose.exchange.yml logs -f --tail=100 op-geth

# 重启节点（不删数据）
docker compose -f docker-compose.exchange.yml restart

# 停止节点（保留数据）
docker compose -f docker-compose.exchange.yml down

# 完全停止并删除数据卷（⚠️ 会清空已同步数据，需重新同步）
docker compose -f docker-compose.exchange.yml down -v
```

> 重启后节点会从上次同步位置继续，无需重新初始化。

---

## 四、查询命令

所有查询走本地节点（端口见 `.env`：op-geth 默认 `9545`，op-node 默认 `9547`）。

```bash
U=http://127.0.0.1:9545

# 链 ID
curl -s -X POST $U -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'

# 最新块高
curl -s -X POST $U -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}'

# 地址余额（wei，十六进制）
curl -s -X POST $U -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_getBalance","params":["0x<ADDRESS>","latest"]}'

# 交易详情 / 收据（确认交易是否上链）
curl -s -X POST $U -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_getTransactionByHash","params":["0x<TXHASH>"]}'
curl -s -X POST $U -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_getTransactionReceipt","params":["0x<TXHASH>"]}'

# 同步状态三头（建议入账确认以 safe 为准）
curl -s -X POST http://127.0.0.1:9547 -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"optimism_syncStatus","params":[]}' \
  | jq '{unsafe: .result.unsafe_l2.number, safe: .result.safe_l2.number}'
```

---

## 五、发送交易

标准 EVM 流程（与以太坊一致）：

1. **签名**：在交易所钱包系统离线签名，`chainId` 必须填链上实际值（见 `.env` 的 `L2_CHAIN_ID`）
2. **广播**：

```bash
curl -s -X POST $U -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransaction","params":["0x<签名后的raw tx>"]}'
```

3. **确认**：轮询 `eth_getTransactionReceipt` 直到非 null，且 `status=0x1`、`blockNumber` 有值

> **确认策略**：充值入账建议以 `safe` 块为准（见上节三头查询），确认数由交易所业务策略决定。

---

## 六、注意事项

| 项 | 说明 |
|----|------|
| 磁盘 | 链数据持续增长，建议按至少 24 个月余量规划，剩余空间低于 20% 需告警 |
| 存储模式 | `.env` 中 `OP_GETH_GCMODE` / `OP_GETH_STATE_SCHEME` 默认 `full`+`path`；`archive`+`hash` 支持全历史查询但磁盘占用高数倍 |
| 镜像版本 | `OP_GETH_IMAGE` / `OP_NODE_IMAGE` 由项目方指定，**请勿自行更换版本**（跨版本可能产生共识差异） |
| 安全 | 节点 RPC 端口默认仅监听本机；如需对外提供服务，建议通过内网 / 反向代理 + 访问控制暴露，切勿直接暴露公网 |
| 动态出口 IP | 若节点出口 IP 变化，需通知项目方更新访问白名单 |

---

## 七、常见问题

| 现象 | 处理 |
|------|------|
| `safe` 块高不涨 | 检查 `.env` 的 `L1_PROXY_UPSTREAM` 是否可达、L1 是否正常出块 |
| 发交易返回 hash 但 receipt 一直 null | 检查 `L2_SEQUENCER_HTTP` 是否配置正确、转发端点是否可达 |
| 重启后卡在同步 | `docker compose logs op-node` 查看日志；多数情况等待即可恢复 |
| `txpool is full` | 单地址在途交易过多，按 nonce 顺序提交并做退避重试 |

---

## 附：联系与支持

- 节点同步 / 部署问题：联系项目方运维
- 需提供的信息：节点出口公网 IP（用于访问白名单）
