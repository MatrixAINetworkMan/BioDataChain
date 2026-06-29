# 机器 #7：Blockscout 区块浏览器（L1 + L2）

> 角色：独立浏览器服务器，索引 L2（chainId 175700）与可选的 L1（chainId 901）。Postgres + backend + frontend + verifier + stats 微服务。
> **indexer 的 RPC 指向只读副本（#5/#6），不要指主 sequencer**（避免给出块节点加查询压力、也避免 pre-confirmation reorg 抖动）。
> 参考：`dev/blockscout-standalone/运维交接文档.md`、`dev/blockscout/`、`dev/l1/`（L1 浏览器）。

---

## 1. 硬件

| 项 | 推荐 | 最低 |
|---|---|---|
| CPU | 8 vCPU | 4 vCPU |
| 内存 | 32 GB（Postgres + 多容器 ~2.5GB 起，随链增长）| 16 GB |
| 磁盘 | SSD/NVMe 1–2 TB（Postgres 随链单调增长）| 1 TB |

> L1 + L2 两套浏览器可合在一台（DB/容器/网络相互独立），也可拆两台。

## 2. 端口 / 防火墙

| 端口 | 用途 | 范围 |
|---|---|---|
| 22 | SSH | 白名单 |
| 4000 | L2 前端 | 经 #8 LB（HTTPS）|
| 4001 | L2 backend API + WS | 经 #8 LB |
| 4002 | L2 stats 微服务 | 经 #8 LB |
| 5432/6379 | Postgres/Redis | 仅容器内部 |

## 3. 部署 L2 浏览器

```bash
cd /data/code/mychain/dev
cp .env.example .env && vim .env
```

`.env` 关键项：

```bash
PUBLIC_HOST=<本机或浏览器域名>
L2_CHAIN_ID=175700               # 与链一致（.env.flashblocks 也覆盖）
NATIVE_TOKEN_SYMBOL=MAN

# indexer 指向只读副本（不是主 sequencer！用 #5 的内网地址）
BLOCKSCOUT_INDEXER_RPC=http://<副本#5内网IP>:9545
BLOCKSCOUT_INDEXER_TRACE_RPC=http://<副本#5内网IP>:9545
BLOCKSCOUT_INDEXER_WS=ws://<副本#5内网IP>:9546

# 反代域名（配合 #8 nginx）
BLOCKSCOUT_PUBLIC_URL=https://scan.example.com
BLOCKSCOUT_STATS_PUBLIC_URL=https://stats.example.com

# 生产务必重生成（>=64 字符）：mix phx.gen.secret 64
BLOCKSCOUT_SECRET_KEY_BASE=<重新生成的强随机串>
```

启动：

```bash
make pull-blockscout     # 预拉镜像（~2GB）
make blockscout-up       # 起完整版（含 stats），首次 1-2 分钟跑迁移 + 从 0 索引
make blockscout-status
make blockscout-logs     # 看 backend 追块进度
```

> 生产建议 pin 镜像 digest 防 `:latest` 漂移：`make blockscout-pin`。

## 4. 部署 L1 浏览器（可选，同机或另机）

```bash
cd /data/code/mychain/dev/l1
# .env 里 indexer 默认指本机 L1 geth；生产建议指 L1 热备(#2)的 RPC，别压主出块节点
make blockscout-up
make blockscout-ps
```

## 5. 验收

- L2 浏览器首页块号**持续增长并追上链头**；
- 交易/合约/token（MAN）正常显示；
- stats 页（Daily transactions 等）有数据；
- 实时刷新生效（依赖 #8 nginx 的 `/socket/` WebSocket 反代头）。

## 6. 运维

```bash
make blockscout-logs-backend     # 追块/reorg 日志
make blockscout-clean            # ⚠️ 清索引重建（不动链数据）
```

- indexer 指向的副本若换机/重建，改 `BLOCKSCOUT_INDEXER_RPC` 后 `make blockscout-down && make blockscout-up`。
- Postgres 定期备份;磁盘告警(随链增长)。
