# Blockscout 独立机器部署 + 运维手册

把区块浏览器（Blockscout）从链节点机器拆出来，单独跑一台机器。链
（`op-geth` / `op-node` / `op-batcher` / L1）继续待在原机器，本机只跑浏览器，
通过网络访问链的 RPC 来索引数据。

```
┌─────────────────────────┐         RPC (HTTP/WS/trace)        ┌──────────────────────────┐
│  链机器                  │ ◀───────────────────────────────  │  浏览器机器 (本套部署)    │
│  op-geth :9545/:9546     │                                   │  blockscout-backend       │
│  op-node / batcher       │         L1 RPC :8545              │  blockscout-frontend      │
│  L1 geth :8545 (或独立机) │ ◀───────────────────────────────  │  stats / db / redis ...   │
└─────────────────────────┘                                   └──────────────────────────┘
```

---

## 一、前置要求

### 1. 本机（浏览器机器）
- Linux + Docker 20.10+ + `docker compose` v2
- 工具：`jq`、`envsubst`（`gettext-base`）、`curl`、`openssl`
  ```bash
  sudo apt update && sudo apt install -y docker-compose-plugin jq gettext-base curl openssl
  ```
- 内存 ≥ 4G（backend Elixir + 两个 Postgres 比较吃内存），磁盘 ≥ 50G（索引数据随链增长）
- 一个解析到本机公网 IP 的域名（如 `scan.example.com`）+ HTTPS 证书

### 2. 链机器必须对本机暴露的端口
Blockscout 索引依赖**远程 RPC**，链机器需要让本机能访问到：

| 用途 | 默认端口 | 说明 |
|------|---------|------|
| L2 op-geth HTTP | `9545` | `eth_*`，且 **`--http.api` 必须含 `debug`**（internal txns / trace 要用） |
| L2 op-geth WS | `9546` | 实时索引（newHeads 订阅）必需 |
| L1 geth HTTP | `8545` | optimism 跨链索引（deposit / withdrawal / batch） |

两种暴露方式二选一：
- **私网直连（推荐）**：两机在同一 VPC/内网，安全组放行上述端口给本机内网 IP。`.env` 里
  填 `http://<内网IP>:9545` / `ws://<内网IP>:9546`。最快、最省心。
- **公网 HTTPS 反代**：走 nginx 暴露 `https://dev.example.com/rpc` + `wss://dev.example.com/ws`。
  需要在链机器 nginx 加 `/rpc` 和 `/ws`（参考 `dev/l1/nginx/devl1.example.com.conf` 里的写法）。

> 安全提示：RPC 端口直接对**整个公网**敞开有风险（`debug_*` 可被滥用）。优先用安全组
> 只放行本机 IP，或走带访问控制的 nginx。

---

## 二、一键部署

```bash
# 1. 把这个目录拷到浏览器机器（git clone 整个仓库，或只拷 dev/blockscout-standalone）
cd dev/blockscout-standalone

# 2. 品牌素材：assets/{logo.svg,icon.svg,logo512.png} 已随仓库自带；
#    favicon/ 子目录会由 install.sh 在首次跑时自动调 scripts/make-favicon.sh
#    用 docker 镜像 dpokidov/imagemagick 现场生成（约 60s + 首次拉镜像 ~200MB）。
#    要换品牌图：直接覆盖 assets/{logo.svg,icon.svg,logo512.png}，再跑
#    bash scripts/make-favicon.sh --force 即可。

# 3. 配置
cp .env.example .env
vim .env        # 把所有 REPLACE_ME 改成真实值（见下方「配置项说明」）

# 4. 一键安装（自检 → 渲染 → 生成 favicon → 拉镜像 → 起服务 → 等健康）
./install.sh

# 5. 配 nginx 反代（HTTPS 入口）
sudo cp nginx/blockscout.conf.example /etc/nginx/conf.d/scan.example.com.conf
sudo vim /etc/nginx/conf.d/scan.example.com.conf   # 改 server_name / ssl 证书路径
sudo nginx -t && sudo systemctl reload nginx
```

`install.sh` 跑完会打印访问地址。首次启动 backend 要建表 + 索引创世，**1–3 分钟**后
首页才有数据。

### 配置项说明（`.env` 必填）
| 变量 | 从哪来 |
|------|--------|
| `L2_RPC_HTTP` / `L2_RPC_WS` / `L2_RPC_TRACE` | 链机器 op-geth 的可达地址 |
| `L2_RPC_PUBLIC_URL` | 给终端用户钱包用的公网 HTTPS RPC（如 `https://dev.example.com/rpc`） |
| `L1_RPC` | L1 机器 geth 的可达地址 |
| `L2_CHAIN_ID` | 链机器 `eth_chainId`（`.env` 里的 `L2_CHAIN_ID`） |
| `OPTIMISM_PORTAL_PROXY` 等 4 个合约地址 | 链机器 `cat workdir/shared/l1-addresses.env` |
| `BATCH_INBOX_ADDRESS` | 链机器 `jq .batch_inbox_address workdir/shared/rollup.json` |
| `BLOCKSCOUT_PUBLIC_URL` | 本机浏览器对外域名，如 `https://scan.example.com` |
| 5 个 `*_IMAGE` digest | 跟链机器保持一致（见「升级」一节） |

---

## 三、日常运维

所有命令在 `dev/blockscout-standalone/` 目录执行。

### 看状态 / 日志
```bash
docker compose ps                      # 8 个容器状态
docker compose logs -f backend         # 索引器日志（最常看）
docker compose logs -f frontend stats  # 前端 / 图表
docker stats                           # 内存 / CPU 占用
```

### 起停 / 重启
```bash
docker compose up -d                   # 起（或应用改动）
docker compose restart backend         # 单独重启某服务
docker compose down                    # 停（保留数据）
docker compose down -v                 # 停 + 删库（⚠️ 清空索引，需重新同步整条链）
```

### 改配置后生效
改完 `.env` 或 `envs/*.tpl` 后，重新跑 `./install.sh` 即可（幂等，会重渲染 + 滚动更新）。
只改了 `.env` 想快速重渲染也行：
```bash
./install.sh
```

### 升级 Blockscout

⚠️ **后端 optimism flavor 没有公开新镜像，必须自编译。**
Blockscout 自 v10 起不再发布公开 optimism 镜像：`ghcr.io/blockscout/blockscout-optimism`
永久停在 **9.0.2**（10/11 全 404），v10/v11 只推私有仓库 `blockscout-optimism-private`（外部拉不了）。
又因 optimism 是「编译期」chain type，通用 `blockscout` 镜像不能索引 OP 的 deposit/withdrawal/batch，
所以后端要上 v11 **只能从源码自己编译**。**前端同样**——公开镜像 `ghcr.io/blockscout/frontend`
永久停在 **v2.3.5**（`:latest` 也指向它），v2.7/v2.8 只推私有仓库 `frontend-private`，要新版也得自编译。
stats / verifier / sig-provider 是 flavor 无关的公开镜像，照常用官方 tag。

#### 1) 自编译 optimism 后端镜像（以 v11.2.0 为例）
```bash
# 需要 docker + git，构建较重（Elixir 编译，约 4GB+ 内存、15–30 分钟）
cd /data
git clone --depth 1 --branch v11.2.0 https://github.com/blockscout/blockscout.git blockscout-src
cd blockscout-src
DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile \
  --build-arg CHAIN_TYPE=optimism \
  --build-arg RELEASE_VERSION=11.2.0 \
  --build-arg BLOCKSCOUT_VERSION=v11.2.0 \
  -t blockscout-optimism:11.2.0-local .
# 校验版本
docker run --rm --entrypoint sh blockscout-optimism:11.2.0-local -c 'echo $RELEASE_VERSION'   # 期望 11.2.0
```

#### 2) 自编译前端镜像（以 v2.8.0 为例）
```bash
# 构建峰值 ~8GB 内存（Dockerfile 写死 --max-old-space-size=8192），内存不足先加 swap：
#   sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
cd /data
git clone --depth 1 --branch v2.8.0 https://github.com/blockscout/frontend frontend-src
cd frontend-src
# GIT_TAG 让页脚正确显示版本号；纯 docker build，配置是运行时注入（entrypoint.sh）
docker build -f Dockerfile --build-arg GIT_TAG=v2.8.0 -t blockscout-frontend:2.8.0-local .
```
> v2.3.5（公开 `:latest`）配 v11 也能跑，但偏旧、OP 新页面可能显示不全；v2.8.0 与 v11 后端最佳兼容。

#### 3) stats / verifier / sig-provider 取 digest（flavor 无关，公开镜像）
```bash
ST=ghcr.io/blockscout/stats:latest               # 必须 ≥ v2.16.0（适配后端 v11 表结构）
VF=ghcr.io/blockscout/smart-contract-verifier:latest
SP=ghcr.io/blockscout/sig-provider:latest
for i in "$ST" "$VF" "$SP"; do docker pull "$i"; done
echo "BLOCKSCOUT_BACKEND_IMAGE=blockscout-optimism:11.2.0-local"
echo "BLOCKSCOUT_FRONTEND_IMAGE=blockscout-frontend:2.8.0-local"
echo "BLOCKSCOUT_STATS_IMAGE=$(docker inspect --format '{{index .RepoDigests 0}}' "$ST")"
echo "BLOCKSCOUT_VERIFIER_IMAGE=$(docker inspect --format '{{index .RepoDigests 0}}' "$VF")"
echo "BLOCKSCOUT_SIG_PROVIDER_IMAGE=$(docker inspect --format '{{index .RepoDigests 0}}' "$SP")"
```
把这 5 行填回 `.env` 的对应变量（后端 / 前端是本地自编译 tag，其余钉 digest）。

#### 4) 应用
- **从 9.x 跨到 v11**：官方要求 v11 必须装在 v10.1 之上，无法直接迁移。要么自编译 v10.1.x 先迁移再上
  v11，要么（推荐，尤其测试环境）**greenfield 清库重装**——v11 可直接全新安装：
```bash
cd /data/mychain/dev/blockscout-standalone
docker compose --env-file .env down -v                       # ⚠️ 清空索引，整条链会重新同步
./install.sh                                                  # 已支持本地镜像（pull --ignore-pull-failures）
docker compose logs -f backend                               # 看 v11 建表 + 重新索引
```
- **同大版本内换补丁**：直接改 `.env` 镜像版本后 `./install.sh` 即可（backend 启动自动 `create_and_migrate()`）。

> 升级前务必备份（见下）。`install.sh` 的 `pull` 已带 `--ignore-pull-failures`，本地自编译后端不会因拉取失败而中断。

### 备份 / 恢复
索引数据在 `bs-db` 卷（主库）和 `bs-stats-db` 卷（图表库）。
```bash
# 备份主库
docker compose exec -T db pg_dump -U blockscout blockscout | gzip > backup-$(date +%F).sql.gz

# 恢复
gunzip -c backup-2026-06-01.sql.gz | docker compose exec -T db psql -U blockscout blockscout
```
> Blockscout 的数据可从链「重新索引」得到，所以备份不是强制的；但全量重索引耗时随链
> 长度增长，定期备份能省恢复时间。

### 重新索引整条链
链重建（chainId 或创世变了）后，旧数据对不上，需要清库重来：
```bash
docker compose down -v        # 删 bs-db / bs-redis / bs-stats-db
./install.sh                  # 重新起，从创世重新索引
```

### 磁盘 / 日志清理
日志已限制单容器 20m×5 文件。清 docker 垃圾：
```bash
docker system prune -f
docker volume ls              # 确认只删该删的卷
```

---

## 四、排障速查

| 症状 | 排查 |
|------|------|
| 首页一直 "Something went wrong" | `docker compose logs frontend`；多半是 `NEXT_PUBLIC_*` 地址不对（重渲染 `./install.sh`） |
| 首页 Daily transactions 一直 0 | stats 没连上：`docker compose logs stats`；确认 `BLOCKSCOUT_STATS_PUBLIC_URL` + nginx `/stats-api/` 通 |
| 区块号不涨 / 不索引新块 | backend 连不上 L2 RPC：`docker compose logs backend \| grep -i rpc`；查 `L2_RPC_HTTP/WS` 连通性、`debug` 是否开 |
| 余额显示 0 但链上有 | 索引滞后，正常；高 TPS 下 backend 余额异步刷新，稍等或访问 `/api/v2/addresses/{addr}` 触发刷新 |
| deposit/withdrawal tab 空 | L1 索引失败：查 `L1_RPC` 连通 + 5 个合约地址填对 |
| 钱包 "Add network" 报 RPC 无效 | `L2_RPC_PUBLIC_URL` 必须是 **HTTPS**，不能是 `http://IP:port` |
| WS 实时不刷新（需手动 F5） | nginx 缺 `map $http_upgrade $connection_upgrade`，或 backend `CHECK_ORIGIN` 拦了 Origin |
| frontend 启动报 `not a directory` mount `favicon.ico` | `assets/favicon/` 缺文件，docker bind-mount 时自动 mkdir 出"伪目录"。`docker compose stop frontend && docker compose rm -f frontend && bash scripts/make-favicon.sh --force && docker compose up -d frontend`（脚本会自动清理伪目录后重新生成） |

快速连通性自检（在本机跑）：
```bash
source .env
curl -s -X POST "$L2_RPC_HTTP" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
curl -s "http://127.0.0.1:${BLOCKSCOUT_API_PORT}/api/v2/blocks?limit=1"
```

---

## 五、目录结构

```
dev/blockscout-standalone/
├── .env.example              # 配置模板（cp 成 .env 再填）
├── docker-compose.yml        # 8 服务，自包含网络 blockscout-net
├── install.sh                # 一键安装/更新（自检+渲染+生成 favicon+起服务）
├── envs/
│   ├── backend.env.tpl       # backend 环境模板（→ 渲染成 backend.env）
│   └── frontend.env.tpl      # frontend 环境模板（→ 渲染成 frontend.env）
├── nginx/
│   └── blockscout.conf.example  # nginx 反代示例
├── scripts/
│   └── make-favicon.sh       # 从 assets/{icon.svg|logo512.png} 用 ImageMagick 生成 9 件套 favicon
├── assets/                   # 品牌素材（入库的源 + 派生 favicon/）
│   ├── logo.svg              # nav 头部 logo（入库）
│   ├── icon.svg              # 方形 icon（入库，favicon 源）
│   ├── logo512.png           # 512px PNG（入库，favicon 优先源）
│   └── favicon/              # 9 件套，install.sh 首次跑时自动生成；可选入库
└── README.md                 # 本文档
```
