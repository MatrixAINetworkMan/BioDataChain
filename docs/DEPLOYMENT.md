# MAN L2 — 部署与运维手册

> **本文档面向运维同学，覆盖从一台干净的 Linux 服务器到对外可用的完整部署。**
>
> 当前部署形态：**OP Stack v6.0.0 + CGT v2 + 自定义原生资产 MAN**，单机 Docker Compose 编排，包含主链 + Blockscout 浏览器（含 stats 微服务）+ 可选刷量机器人。
>
> 对外形态：`https://demo.example.com`（浏览器入口）+ `http://<IP>:9545`（L2 RPC）。

---

## 目录

1. [整体拓扑](#1-整体拓扑)
2. [服务器与网络要求](#2-服务器与网络要求)
3. [初装步骤](#3-初装步骤)
4. [.env 配置详解](#4-env-配置详解)
5. [nginx 反向代理配置](#5-nginx-反向代理配置)
6. [启动主链](#6-启动主链)
7. [启动 Blockscout 浏览器](#7-启动-blockscout-浏览器)
8. [对外开放与验证](#8-对外开放与验证)
9. [日常运维命令](#9-日常运维命令)
10. [刷量机器人（可选）](#10-刷量机器人可选)
11. [故障排查](#11-故障排查)
12. [完全重建 / 数据归零](#12-完全重建--数据归零)
13. [安全与生产化注意事项](#13-安全与生产化注意事项)
14. [代码与目录结构](#14-代码与目录结构)

---

## 1. 整体拓扑

```
                           ┌──────────── 浏览器 / 钱包 / dApp ──────────┐
                           │                                            │
                  HTTPS 443│              TCP 9545/9546                  │
                           ▼                                            ▼
                   ┌──────────────┐                          ┌────────────────┐
                   │    nginx     │                          │   op-geth      │
                   │ TLS 终止 +   │ ──/, /api, /socket──▶   │ (RPC 8545      │
                   │ 反向代理     │ ──/stats-api/───────▶   │  WS  8546)     │
                   └──────────────┘                          └────────────────┘
                          │
        ┌─────────────────┼─────────────────────────────────────┐
        │                 │                                     │
        ▼                 ▼                                     ▼
 ┌─────────────┐  ┌──────────────────┐               ┌────────────────────┐
 │ frontend    │  │ backend (4001)   │               │ stats (4002)       │
 │ Next.js     │  │ Phoenix Indexer  │ ──reads DB──▶ │ Rust microservice  │
 │ (4000)      │  │ + REST API       │               │ + 独立 stats-db     │
 └─────────────┘  └──────────────────┘               └────────────────────┘
                          │                                     │
                          ▼                                     ▼
                  ┌─────────────────┐                  ┌─────────────────┐
                  │  blockscout-db  │                  │   stats-db      │
                  │  (postgres 16)  │                  │  (postgres 16)  │
                  └─────────────────┘                  └─────────────────┘

                                   docker network: mychain-dev

                  ┌────────────────────────────────────────────────┐
                  │  主链（op-deployer 一次性 + 长驻服务）           │
                  │    anvil (L1, 假以太坊)                         │
                  │    op-geth + op-node (sequencer)                │
                  │    op-batcher (写 L1 batch)                     │
                  │    op-proposer (state root，dev 阶段不开)       │
                  └────────────────────────────────────────────────┘
```

**网络层**：所有 Docker 容器都挂在 `mychain-dev` 这个 user-defined bridge 上，互相用 service 名解析。Blockscout 是**独立 docker-compose**（在 `dev/blockscout/`），通过 `external network` 接进 `mychain-dev`，跟主链解耦——停浏览器不影响主链，反之亦然。

---

## 2. 服务器与网络要求

### 2.1 硬件 / OS

| 项 | dev / 演示 | Sepolia 阶段 |
|---|---|---|
| OS | Ubuntu 22.04 / 24.04 LTS | 同左 |
| vCPU | 4 核 | 8 核 |
| 内存 | 16 GB | 32 GB |
| 磁盘 | 200 GB SSD | 1 TB NVMe SSD |
| Docker | ≥ 24.x，含 Compose plugin v2.x | 同左 |

### 2.2 必装软件

```bash
# Docker（如还没装）
curl -fsSL https://get.docker.com | sudo bash
sudo usermod -aG docker work
# 务必 logout 再 login，让 docker 组生效

# nginx + certbot（反向代理 + Let's Encrypt 自动续签）
sudo apt update
sudo apt install -y nginx certbot python3-certbot-nginx jq

# 验证
docker --version
docker compose version
nginx -v
```

### 2.3 端口规划

下面是当前部署用到的端口。**严格按这张表配 AWS Security Group / iptables**。

| 端口 | 协议 | 对外? | 作用 | 备注 |
|---|---|---|---|---|
| 22 | TCP | 仅运维 IP | SSH | 限白名单 |
| 80 | TCP | 全网 | HTTP → 443 重定向 | nginx |
| 443 | TCP | 全网 | HTTPS：Blockscout 主站 + stats-api | nginx 终止 TLS |
| 9545 | TCP | 全网 | L2 op-geth HTTP RPC | 钱包 / cast / 合约部署 |
| 9546 | TCP | 全网 | L2 op-geth WebSocket | dApp 订阅 |
| 8545 | TCP | 仅本机 / 调试 | L1 anvil RPC | 默认对外不开 |
| 9547 | TCP | 仅本机 / 调试 | op-node RPC | 默认对外不开 |
| 4000 | TCP | 仅本机 | Blockscout frontend (loopback) | nginx 反代到这 |
| 4001 | TCP | 仅本机 | Blockscout backend API (loopback) | nginx 反代到这 |
| 4002 | TCP | 仅本机 | Blockscout stats (loopback) | nginx /stats-api/ 反代到这 |

> **重要**：4000/4001/4002 用了 nginx 反代后，**AWS 安全组不要对外开**，免得 HTTP 入口绕过 HTTPS。

### 2.4 域名 / DNS

需要一个域名。当前生产用的是 `demo.example.com`：

```
demo.example.com.   A   <服务器外网 IP>
```

不需要给 stats 加独立子域名——本文档采用 `https://demo.example.com/stats-api/` 路径反代方案，省一套 DNS + 证书。

---

## 3. 初装步骤

### 3.1 拿代码

```bash
# 推荐路径 /data/code/mychain（Makefile 里硬编码无关，但日志/文档示例都用这个）
sudo mkdir -p /data/code
sudo chown $USER:$USER /data/code
cd /data/code

git clone <仓库 URL> mychain
cd mychain/dev
```

### 3.2 创建工作用户（可选）

如果还没有运维专用用户：

```bash
sudo useradd -m -s /bin/bash -G docker,sudo work
sudo passwd work
# 后续命令一律切到 work：sudo -iu work
```

---

## 4. .env 配置详解

```bash
cd /data/code/mychain/dev
cp .env.example .env
```

**必改的 3 项**：

```diff
- PUBLIC_HOST=
+ PUBLIC_HOST=13.158.71.128                                # 改成本机外网 IP

- BLOCKSCOUT_PUBLIC_URL=
+ BLOCKSCOUT_PUBLIC_URL=https://demo.example.com           # nginx 主站

- BLOCKSCOUT_STATS_PUBLIC_URL=
+ BLOCKSCOUT_STATS_PUBLIC_URL=https://demo.example.com/stats-api  # 见 §5
```

**其他变量保持默认即可**（dev 阶段，所有私钥都是 anvil 公开 key，主网部署时见 §13）。

完整 .env 字段说明：

| 变量 | 默认值 | 何时改 |
|---|---|---|
| `PUBLIC_HOST` | _空_ | **必填**，外网 IP 或域名 |
| `L2_CHAIN_ID` | `42170` | 想换链 ID 时（改了必须 `make dev-clean` 重建） |
| `L2_BLOCK_TIME` | `3` | 出块周期（秒），改了必须 `make dev-clean` 重建 |
| `NATIVE_TOKEN_NAME` | `Matrix AI Network` | 钱包/浏览器显示的 native asset 名字 |
| `NATIVE_TOKEN_SYMBOL` | `MAN` | 钱包/浏览器显示的 native asset 符号 |
| `BLOCKSCOUT_PUBLIC_URL` | _空_ | 反代必填，**没填会变直连模式（HTTP，浏览器拉黑）** |
| `BLOCKSCOUT_STATS_PUBLIC_URL` | _空_ | 反代必填，**没填首页 Daily transactions tile 显示 0** |
| `BLOCKSCOUT_*_IMAGE` | `:latest` | 主网 pin 死版本号 |
| `BLOCKSCOUT_SECRET_KEY_BASE` | dev 占位串 | **主网必须** `mix phx.gen.secret 64` 重新生成 |
| `*_PRIVATE_KEY` (5 个角色) | anvil 公开 key | **主网必须**换成真实 KMS / 多签 |

---

## 5. nginx 反向代理配置

### 5.1 申请证书

```bash
sudo certbot --nginx -d demo.example.com
# 第一次会问邮箱、同意 ToS、是否重定向 HTTP→HTTPS（选 Yes）
# certbot 会自动写一个最小 server 块到 /etc/nginx/sites-enabled/demo.example.com
```

### 5.2 完整 server 配置

把下面这段**整体替换**掉 certbot 生成的最小配置（同时保留 certbot 写的 SSL 路径行）：

```bash
sudo tee /etc/nginx/sites-available/demo.example.com > /dev/null <<'NGINX'
# 80 → 443 重定向（certbot 会自动维护这块，不用手写）
server {
    listen 80;
    listen [::]:80;
    server_name demo.example.com;
    return 301 https://$host$request_uri;
}

# 主站 HTTPS：Blockscout 前端 + 后端 API + stats 微服务（path 反代）
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name demo.example.com;

    # 由 certbot 维护
    ssl_certificate     /etc/letsencrypt/live/demo.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/demo.example.com/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    # 大请求 body（合约 verify 上传 .sol 源文件）
    client_max_body_size 20m;

    # WebSocket 长连接超时（前端实时块/交易推送走 /socket）
    proxy_read_timeout  3600s;
    proxy_send_timeout  3600s;

    # ─── stats 微服务（首页 Daily transactions / Charts 全靠它）──────────────
    # 注意 proxy_pass 末尾的 / 会把 /stats-api/ 前缀剥掉再转发
    location /stats-api/ {
        proxy_pass http://127.0.0.1:4002/;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
    }

    # ─── Blockscout 后端 API + WebSocket（实时推送）───────────────────────
    # /api、/socket、/sitemap.xml、/auth/* 都打到 backend(4001)
    location ~ ^/(api|socket|sitemap\.xml|auth)(/|$) {
        proxy_pass http://127.0.0.1:4001;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        # WebSocket 升级
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        "upgrade";
    }

    # ─── 其他全部走 Blockscout frontend（Next.js）──────────────────────────
    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
    }
}
NGINX

sudo ln -sf /etc/nginx/sites-available/demo.example.com /etc/nginx/sites-enabled/demo.example.com
sudo nginx -t && sudo systemctl reload nginx
```

### 5.3 证书自动续签

certbot 会自动在 `/etc/cron.d/certbot` 装一个续签 cron。手动验证：

```bash
sudo certbot renew --dry-run
```

---

## 6. 启动主链

### 6.1 预拉镜像（首次约 5 分钟）

```bash
cd /data/code/mychain/dev
make pull            # 主链 5 个镜像（anvil + op-deployer + op-geth + op-node + op-batcher + op-proposer）
make pull-blockscout # Blockscout 5 个镜像，约 2 GB
```

### 6.2 一键拉起主链

```bash
make dev-up
```

`dev-up` 内部按顺序跑：

1. `check-env` — 校验 .env 必填项 + 工具齐全
2. `render-intent` — `intent.toml.example` envsubst 成 `workdir/intent.toml`
3. `l1-up` — 启动 anvil，首次启动把当前时间写进 `.env` 让链时钟从今天开始
4. `deploy-l1` — `op-deployer apply` 部署 L1 合约（CGT v2 全套）
5. `deploy-genesis` — 生成 `genesis.json` + `rollup.json` + `jwt.txt`
6. `init-geth` — 用 patched genesis 初始化 op-geth datadir
7. `l2-up` — 启动 op-geth + op-node + op-batcher
8. `status` + `info` — 显示状态和访问地址

预期耗时：首次 8–12 分钟，已有镜像后 ~3 分钟。

### 6.3 验证主链

```bash
make healthcheck   # 6 项端到端健康
make verify-cgt    # CGT v2 的 10 条核心验收（symbol、isCustomGasToken、NAL 余额、转账、gas 计价等）
```

**两条都全过 = 链没问题**。出问题先看 §11 故障排查。

### 6.4 看链状态

```bash
make status        # 容器状态
make info          # 团队访问 URL（MetaMask 添加参数）
make logs          # tail 全部 OP 服务日志
make logs-op-node  # 单服务（op-node / op-geth / op-batcher / anvil 任选）
```

---

## 7. 启动 Blockscout 浏览器

### 7.1 起 8 个容器

```bash
make blockscout-up
```

容器清单：

| 容器 | 作用 |
|---|---|
| `mychain-blockscout-db` | postgres 16，主索引数据库 |
| `mychain-blockscout-redis` | 缓存 + 实时事件总线 |
| `mychain-blockscout-backend` | Elixir 索引器 + REST/GraphQL API（Optimism flavor） |
| `mychain-blockscout-frontend` | Next.js Web UI |
| `mychain-blockscout-verifier` | Rust 编译验证服务 |
| `mychain-blockscout-sig-provider` | Rust 函数签名解码服务 |
| `mychain-blockscout-stats-db` | postgres 16，stats 微服务专用 |
| `mychain-blockscout-stats` | Rust stats 微服务（首页 Daily transactions + Charts 数据来源） |

首次启动 backend 要建 ~150 张表 + 索引创世块，~1-2 分钟。stats 首次会跑批聚合历史，~1-3 分钟。

### 7.2 链重建会自动 wipe Blockscout DB

`make blockscout-up` 启动时会比对 chain fingerprint（`L2_CHAIN_ID` + L2 genesis hash）。若发现链被重建，自动 `down -v` 把 Blockscout postgres 清掉重建索引——避免新链 + 旧 DB 块号撞上的灾难场景。

### 7.3 Blockscout 状态/日志

```bash
make blockscout-status         # 8 容器状态
make blockscout-logs           # tail backend + frontend
make blockscout-logs-backend   # 单服务（任选 backend / frontend / stats / verifier 等）
make blockscout-logs-stats     # stats 微服务日志（看是否在跑聚合）
```

### 7.4 验证浏览器全链路通

```bash
# 主站
curl -s https://demo.example.com/api/v2/blocks?limit=1 | jq '.items[0].height'
# 期待：返回当前最新块高（数字）

# stats 微服务（关键！）
curl -s https://demo.example.com/stats-api/health | jq
# 期待：{"status":"SERVING"} 或类似

curl -s 'https://demo.example.com/stats-api/api/v1/lines/newTxnsWindow?resolution=DAY&from=2026-04-01' | head -c 200
# 期待：返回 JSON（首次启动可能为空 [] 数组，等 stats 跑完聚合后有数据）
```

浏览器打开 `https://demo.example.com`，验证：

- [ ] 左上角 logo + 网络名 `MAN Dev` 正常显示
- [ ] Total blocks / Total transactions 在涨
- [ ] **Daily transactions tile 显示数字**（不是 0；首次启动等 1-3 分钟）
- [ ] 浏览器 DevTools → Network 没有 Mixed Content 错误

---

## 8. 对外开放与验证

### 8.1 给团队的接入文档

`docs/TEAM_ACCESS.md` 是给开发同事看的接入指南，包含：

- L2 / L1 网络参数
- MetaMask / Rabby 添加网络步骤
- 测试用 EOA 私钥（dev 公开 key）
- Blockscout 入口
- 5 分钟 Smoke Test
- 常见问题

链重建后要更新该文档里的 "最近一次重建" 日期。

### 8.2 对外 Smoke Test

随便找台外网机器（或自己手机热点）：

```bash
# 1. L2 RPC 通
curl -X POST https://demo.example.com/api/v2/health \
  -o /dev/null -w '%{http_code}\n'   # 200

curl -X POST http://13.158.71.128:9545 \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
# 期待: {"jsonrpc":"2.0","id":1,"result":"0xa4ba"}   ← 42170

# 2. WebSocket 通（需要 wscat）
# wscat -c ws://13.158.71.128:9546

# 3. Explorer 通
curl -I https://demo.example.com   # 200
curl -I https://demo.example.com/stats-api/health   # 200
```

### 8.3 浏览器侧验证

DevTools → Network 看不到任何 **Mixed Content** 红色阻断；DevTools → Console 没有 `useFetch` 报错。如果有，多半是 §5 的 nginx 配置漏了 `/stats-api/` 那段。

---

## 9. 日常运维命令

### 9.1 总览

```bash
make help          # 看完整命令清单
```

### 9.2 主链

| 命令 | 说明 |
|---|---|
| `make status` | 主链 docker 服务状态 |
| `make info` | 打印对外访问参数 |
| `make logs` | tail 全部主链日志 |
| `make logs-op-node` | 单服务日志（op-geth / op-batcher / anvil 任选） |
| `make healthcheck` | 6 项端到端检查 |
| `make verify-cgt` | CGT v2 10 条核心验收 |
| `make dev-down` | 停主链（保留 volume，下次 `dev-up` 续跑） |
| `make dev-restart` | 销毁 + 重建（dev 阶段常用） |

### 9.3 Blockscout

| 命令 | 说明 |
|---|---|
| `make blockscout-status` | 8 容器状态 |
| `make blockscout-logs` | tail backend + frontend |
| `make blockscout-logs-stats` | 单看 stats 微服务 |
| `make blockscout-down` | 停（保留 DB，下次起来不用重新索引） |
| `make blockscout-favicon` | 改了 `dev/blockscout/assets/icon.svg` 后跑（重新生成 favicon 套件） |

### 9.4 给团队成员发钱

```bash
make fund TO=0xYourAddr AMOUNT=100   # 转 100 MAN
```

### 9.5 同时看主链 + 浏览器

```bash
# 一个 terminal 看主链
make logs

# 另一个 terminal 看 blockscout backend（看 indexer 进度）
make blockscout-logs-backend
```

---

## 10. 刷量机器人（可选）

给浏览器制造持续交易活动，让 Daily transactions / Wallet addresses / Charts 看起来"活"。

### 10.1 一次性准备

```bash
cd /data/code/mychain/dev
make bot-spam-install     # docker 容器里装 npm 依赖（~30s）
make bot-spam-init        # 生成 5642 个钱包到 wallets.json（含私钥，已 gitignore）
make bot-mint AMOUNT=30000000  # 从 NAL 池增发 3000 万 MAN 给 deployer（够 5642 钱包按 200-10000 跑）
```

### 10.2 启动 grow daemon（推荐）

```bash
make bot-grow-up          # 后台 daemon，sigmoid 24h 曲线渐进激活 + 持续 spam
make bot-grow-logs        # tail 日志
make bot-grow-status      # 看容器状态
make bot-grow-down        # 停（active.json 保留，下次续跑）
```

预期效果（24 小时内）：

| 时刻 | 已激活钱包 | Blockscout 表现 |
|---|---|---|
| 启动后 5 分钟 | 29（bootstrap） | wallet addresses ~36 |
| +1h | ~50-80 | 缓慢上升 |
| +12h | ~3000 | tx/day 已经起量 |
| +24h | 5642 | 进入稳态，3-15 tx/s |

### 10.3 故障诊断

| 命令 | 说明 |
|---|---|
| `make bot-ping-tx` | 用 deployer 发 1 wei 自转，验证 mempool 通畅 |
| `make bot-clear-mempool` | 用极高 fee 顶替卡死的 pending tx（不用重启 op-geth） |
| `make bot-spam-status` | 钱包数 / grow 进度 / 抽样余额 |
| `make bot-inspect-lc` | 排查 LiquidityController 状态 |
| `make bot-grow-reset` | 只清 grow 状态（钱包保留），下次从 t=0 开始 |
| `make bot-spam-clean` | 清掉钱包 + node_modules（彻底归零） |

详见 `dev/bots/spammer/README.md`。

---

## 11. 故障排查

### 11.1 主链不出块

```bash
make status                # 看容器是不是都 Up
make logs-op-node          # 找 ERROR
make logs-op-geth
docker logs mychain-anvil --tail=50
```

常见原因：

| 现象 | 可能原因 | 处理 |
|---|---|---|
| op-geth 起不来，报 `genesis not initialized` | datadir 损坏 | `make dev-clean && make dev-up` |
| op-node 报 `cannot connect to L1` | anvil 没起来 / 网络 | 检查 `docker ps` 里 `mychain-anvil` 状态 |
| op-batcher 报 `4844 not supported` | anvil 不支持 blob | `.env` 里 `BATCHER_DA_TYPE=calldata`（默认） |
| `verify-cgt` 第 2 项失败 | op-contracts 版本不对 | 检查 `OP_*_IMAGE` 三件套对应 v6.0.0 |
| safe head 长时间不增长 | batcher 停了 / 资金不够 | `make logs-op-batcher` 找 ERROR |

### 11.2 Blockscout 显示空 / 数据陈旧

```bash
make blockscout-logs-backend | grep -iE 'error|fatal'
```

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 全部空 / 搜不到块 | 索引刚开始，等 1-2 分钟 | 等 |
| 显示旧块、新交易索引不出来 | 链重建过但 DB 没清 | `make blockscout-clean && make blockscout-up`（自动检测指纹应该自动 wipe，但可以手动强制） |
| Daily transactions 一直是 0 | stats 微服务没起 / nginx /stats-api 没配 | §11.3 |
| 浏览器 DevTools 报 Mixed Content | `BLOCKSCOUT_STATS_PUBLIC_URL` 没设成 HTTPS | 改 .env 后 `make blockscout-up` |
| favicon 是默认浏览器图标 | favicon 套件没生成 | `make blockscout-favicon` |
| 容器一直 `(health: starting)` 但日志看到 200 | wget healthcheck localhost IPv6 解析问题 | 等就行（不影响功能），或重启容器 `docker restart mychain-blockscout-backend` |

### 11.3 stats 微服务专项

```bash
# 1. stats 容器在跑吗
docker ps --filter name=mychain-blockscout-stats

# 2. stats 在跑批聚合吗
docker logs mychain-blockscout-stats --tail=50 | grep -iE 'update|chart|complete|error'

# 3. nginx /stats-api/ 通吗（关键！）
curl -i https://demo.example.com/stats-api/health
# 200 + JSON = nginx + stats 都通
# 502/504 = stats 容器没起 → docker logs 看
# 404 = nginx /stats-api/ 路径没配 → 回 §5.2 检查 nginx
```

### 11.4 mempool 卡死（spammer 可能引发）

```bash
make bot-ping-tx          # 看 nonce latest vs pending
# pending > latest → mempool 卡了
make bot-clear-mempool    # 顶替（不用重启 op-geth）
```

如果还卡：`docker compose restart op-geth` 强制清 mempool（会丢未上链的 tx）。

### 11.5 nginx / 证书

```bash
sudo nginx -t                   # 配置语法
sudo systemctl status nginx     # 服务状态
sudo journalctl -u nginx -n 50  # 错误日志
sudo certbot certificates       # 看证书有效期
```

---

## 12. 完全重建 / 数据归零

### 12.1 只重建主链（保留 Blockscout 历史）

```bash
make dev-clean        # 销毁主链 + workdir（不动 blockscout）
make dev-up
# blockscout-up 下次启动时会检测到链重建，自动 wipe DB
make blockscout-up
```

### 12.2 主链 + Blockscout 同时归零

```bash
make dev-clean-all    # 全清（不可恢复）
make dev-up
make blockscout-up
```

### 12.3 只清 Blockscout 数据

```bash
make blockscout-clean
make blockscout-up
```

### 12.4 链重建后必做

1. 通知团队删掉钱包里旧的 `MAN Dev` 网络重新添加（chain_id 没变但合约地址 / nonce 起点变了）
2. 更新 `docs/TEAM_ACCESS.md` 顶部的"最近一次重建"日期
3. 如果跑了刷量 bot：`make bot-spam-clean && make bot-spam-init` 重新生成钱包

---

## 13. 安全与生产化注意事项

> **当前 dev 部署所有私钥都是 anvil 公开 key，仅供内部联调。任何切换到 Sepolia / 主网都必须按此清单做。**

### 13.1 私钥

- 5 个角色私钥（DEPLOYER / BATCHER / PROPOSER / CHALLENGER / SEQUENCER）必须替换为：
  - **DEPLOYER / OWNER_MULTISIG**：Gnosis Safe 多签
  - **BATCHER / PROPOSER**：硬件钱包或 KMS 托管
  - **SEQUENCER / CHALLENGER**：服务器本地 + 严格文件权限

### 13.2 网络隔离

- L1 anvil（dev 用）必须移除，换真实 Sepolia / mainnet RPC（`L1_RPC_URL_INTERNAL` / `L1_RPC_URL_EXTERNAL`）
- op-batcher / op-proposer 跟 op-geth 物理隔离（不同 VM 或 Pod）
- op-geth Admin RPC（`admin_*` namespace）**严禁**对外开

### 13.3 secret 重新生成

```bash
# Blockscout secret_key_base：生产必须独有（影响 cookie 加密）
docker run --rm elixir:alpine \
  sh -c "mix new tmp >/dev/null 2>&1 && cd tmp && mix phx.gen.secret 64" \
  || head -c 64 /dev/urandom | base64 | head -c 80
# 把输出贴到 .env 的 BLOCKSCOUT_SECRET_KEY_BASE
```

### 13.4 镜像版本 pin 死

主网部署前把 `.env` 里所有 `*_IMAGE` 末尾的 `:latest` 换成具体版本号：

```bash
# 当前 dev 用的 OP Stack 三件套（已经 pin 在 .env.example）：
OP_GETH_IMAGE=us-docker.pkg.dev/oplabs-tools-artifacts/images/op-geth:v1.101702.1
OP_NODE_IMAGE=us-docker.pkg.dev/oplabs-tools-artifacts/images/op-node:v1.16.12
OP_BATCHER_IMAGE=us-docker.pkg.dev/oplabs-tools-artifacts/images/op-batcher:v1.16.7
OP_PROPOSER_IMAGE=us-docker.pkg.dev/oplabs-tools-artifacts/images/op-proposer:v1.16.2

# Blockscout 全套（生产改这里）
BLOCKSCOUT_BACKEND_IMAGE=ghcr.io/blockscout/blockscout-optimism:9.0.x
BLOCKSCOUT_FRONTEND_IMAGE=ghcr.io/blockscout/frontend:v2.x.x
BLOCKSCOUT_VERIFIER_IMAGE=ghcr.io/blockscout/smart-contract-verifier:v1.x.x
BLOCKSCOUT_SIG_PROVIDER_IMAGE=ghcr.io/blockscout/sig-provider:v1.x.x
BLOCKSCOUT_STATS_IMAGE=ghcr.io/blockscout/stats:v2.x.x
```

### 13.5 备份

主网部署后必备份的 volume：

| volume | 内容 | 备份频率 |
|---|---|---|
| op-geth datadir (`mychain-op-geth-data`) | L2 区块 / 状态 / chaindata | 每天 |
| Blockscout DB (`bs-db`) | 索引数据（重新索引几小时能恢复，但 token list / verified contracts 丢了就丢了） | 每周 |
| stats DB (`bs-stats-db`) | 聚合结果（可重算，不重要） | 不必 |

### 13.6 防火墙清单（生产）

参照 §2.3，但额外：

- **关闭** 4000 / 4001 / 4002 / 8545 / 9547 的对外暴露（仅 loopback）
- 9545 / 9546（L2 RPC / WS）建议加 nginx + 限速 + IP 白名单（不然容易被 abuse）

---

## 14. 代码与目录结构

```
mychain/
├── docs/
│   ├── DEPLOYMENT.md                  ← 本文档
│   ├── TEAM_ACCESS.md                 ← 给开发同事的接入指南
│   ├── PLAN_OPSTACK_CGTV2.md          ← 当前架构的设计文档
│   └── PLAN_*.md                      ← 历史方案对比（参考用）
└── dev/
    ├── .env.example                   ← 配置模板
    ├── Makefile                       ← 所有 make 命令入口
    ├── docker-compose.yml             ← 主链 docker 编排
    ├── intent.toml.example            ← op-deployer 输入模板
    ├── README.md                      ← dev 阶段总览
    ├── scripts/                       ← 部署 / 健康检查脚本
    │   ├── 00-check-env.sh
    │   ├── 00-render-intent.sh
    │   ├── 01-l1-up.sh
    │   ├── 01-deploy-l1.sh
    │   ├── 02-deploy-genesis.sh
    │   ├── 03-init-geth.sh
    │   ├── healthcheck.sh
    │   ├── verify-cgt.sh
    │   ├── fund.sh
    │   ├── info.sh
    │   ├── blockscout-up.sh           ← Blockscout 启动入口
    │   ├── blockscout-down.sh
    │   └── blockscout-make-favicon.sh ← icon.svg → favicon 套件
    ├── blockscout/
    │   ├── docker-compose.yml         ← Blockscout 8 容器编排
    │   ├── envs/
    │   │   ├── backend.env.tpl        ← envsubst 模板
    │   │   └── frontend.env.tpl
    │   └── assets/
    │       ├── icon.svg               ← 浏览器 logo / favicon 源文件
    │       └── logo.svg
    ├── bots/spammer/                  ← 刷量机器人
    │   ├── spammer.js
    │   ├── package.json
    │   └── README.md
    └── workdir/                       ← 运行时产物（gitignored）
        └── shared/
            ├── genesis.json
            ├── rollup.json
            ├── jwt.txt
            └── l1-addresses.env
```

---

## 15. 联系与参考

- 架构设计 / CGT v2 详情：`docs/PLAN_OPSTACK_CGTV2.md`
- 给开发同事的接入文档：`docs/TEAM_ACCESS.md`
- 刷量机器人详细说明：`dev/bots/spammer/README.md`
- OP Stack 官方文档：https://docs.optimism.io/
- Blockscout 部署文档：https://docs.blockscout.com/setup/

如本文档与代码出现不一致，以代码为准；并请提 PR 修文档。
