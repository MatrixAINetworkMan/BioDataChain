# 机器 #1：L1 主节点（geth Clique PoA）

> 角色：自建 L1 的**出块验证者**，是 L2 的 DA/结算层。chainId 901，2s 出块，LevelDB 持久化。
> 代码：`dev/l1/`（详见 `dev/l1/README.md`）。

---

## 1. 硬件

| 项 | 推荐 | 最低 |
|---|---|---|
| CPU | 8 vCPU（高频）| 4 vCPU |
| 内存 | 32 GB | 16 GB |
| 磁盘 | **本地 NVMe 2–4 TB**（随 L2 的 DA 历史增长，建议留大）| 2 TB |
| 网络 | 10 Gbps，与 L2 机同机房/同 AZ 低延迟 | 1 Gbps |

> 建议把这台设为 **archive / 大 state-history**（`gcmode=archive` 或加大 history），以保留深度回滚/reorg 能力。

## 2. 端口 / 防火墙

| 端口 | 用途 | 开放范围 |
|---|---|---|
| 22 | SSH | 运维白名单 |
| 8545 | geth HTTP RPC | **仅内网**（L2 机 + L1 热备 + 浏览器），勿对公网 |
| 8546 | geth WS | 仅内网 |
| 30303 | p2p | L1 热备/其他 L1 节点 |

> 默认端口只 bind 127.0.0.1，需要给 L2 机访问时把 `BIND_HOST=0.0.0.0` 并用安全组限定来源内网 IP。

## 3. 部署步骤

```bash
cd /data/code/mychain/dev/l1
cp .env.example .env
vim .env
#   必改：
#     PUBLIC_HOST=<本机内网IP>            # L2 机要用这个连
#     VALIDATOR_PASSWORD=<openssl rand -hex 32>
#     BIND_HOST=0.0.0.0                   # 让 L2 机/热备能连（配合安全组限来源）
#   确认：CHAIN_ID=901  PERIOD=2（出块周期）

make init       # 一次性：生成 validator keystore + genesis + geth init
make up         # 启动
make status     # 看 Block# 在涨
sleep 6 && make status   # 再看，应 +3 左右
```

成功标志（`make status`）：`Chain ID: 901`、`Block #` 持续增长、打印出 `Genesis hash` 和 `Validator` 地址余额。

## 4. 记录交接信息（给 L2 机 #3 用）

```bash
# 记下这三项，配置 L2 机时填入
echo "L1 内网IP   = <PUBLIC_HOST>"
echo "L1 chainId  = 901"
docker exec mychain-l1-geth geth attach --exec 'eth.getBlock(0).hash' /data/geth.ipc   # genesis hash
```

## 5. 验收

- `make status` Block# 单调增、不归零；
- 从 L2 机能 `curl http://<L1内网IP>:8545 -d '{"jsonrpc":"2.0","method":"eth_chainId",...}'` 返回 `0x385`(901)；
- 重启不丢数据：`make restart` 后 Block# 接着涨（LevelDB + fsync）。

## 6. 运维

```bash
make logs           # 跟日志
make console        # geth 交互 console
make fund TO=0x...  # validator 给地址转 ETH(L1 gas)
```

- **冷备**（README §6）：`make down && sudo cp -a /var/lib/docker/volumes/mychain-l1-geth-data/_data /data/backup/l1-snap-$(date +%F) && make up`，接 cron 定期做。
- validator keystore (`keystore/`) + `secrets/password.txt` **绝不入仓、单独备份**，丢了无法再出块。

## 7. MAN 创世发钱

L1 预分配了 validator + anvil 标准测试账号。给 OP Stack 角色账号（DEPLOYER/BATCHER/SEQUENCER/PROPOSER）转 L1 gas：

```bash
make fund TO=<DEPLOYER_ADDRESS> AMOUNT=1000
make fund TO=<BATCHER_ADDRESS>  AMOUNT=1000
```
