# MyChain L1 — 独立自建 L1 部署包

一条**完全独立**的 L1 链，go-ethereum (geth) + Clique PoA 共识，**单 validator** 出块，
真正的 LevelDB 持久化（不是 anvil 那种内存 + 快照）。

> 跟 `dev/docker-compose.yml`（anvil + op-stack L2 + Blockscout）**完全解耦**：
> 这里跑起来不影响、不依赖任何其他服务。L1 跑稳后，再单独决定 L2 怎么接。

---

## 1. 设计概览

| 项 | 值 | 说明 |
|---|---|---|
| Client | go-ethereum `v1.13.15` | 最后一个同时稳定支持 shanghai+cancun+Clique 的版本 |
| 共识 | Clique PoA | 单 validator，定时出块（无 tx 也出空块），dev/staging 够用 |
| Chain ID | 901（可改） | 跟现有 anvil dev 链一致 |
| 出块周期 | 2 秒 | Clique `period` 固定，可在 `.env` 改 |
| Gas limit | 30M | 同 Ethereum mainnet，OP Stack 合约部署 + batcher calldata 都够 |
| 持久化 | LevelDB + docker volume `mychain-l1-geth-data` | 真正的 fsync，断电恢复无数据丢失 |
| Validator 私钥 | `make init` 时**当场生成**，放本地 `keystore/` | **严禁入仓**（`.gitignore` 已护住） |
| 预分配账号 | validator + anvil 10 个标准 test 账号，各 10000 ETH | 钱包导入 anvil mnemonic 直接有钱 |
| 端口 | 8545 (HTTP) / 8546 (WS) / 30303 (P2P) | 在 `.env` 可改 |
| 浏览器 | Blockscout（可选） | 与 L1 同一套 `make` 入口管理，独立 docker volume，独立 DB |

### 这是不是"标准、完整"的 L1？

**是。** 用的是 go-ethereum 官方镜像，跟以太坊 mainnet 是同一份 codebase，
只是把共识从 PoS 换成 Clique PoA。执行层（EVM / state / JSON-RPC / mempool /
receipt / log subscription / debug API）**完全等价于 mainnet geth**。

### 断电会不会丢数据？不会。

对比三种方案的持久化原理：

| 方案 | 存储引擎 | fsync | 断电后果 |
|---|---|---|---|
| anvil (dev 用过的) | 内存 + 周期 JSON dump | ❌ | 已知坑：dump 间隔之间全丢 |
| **本方案 (geth Clique)** | LevelDB + WAL | ✅ 每个 block 都 fsync | 最多丢未上链的 mempool tx，已上链数据 0 丢失 |
| 以太坊 mainnet geth | LevelDB + WAL | ✅ | 同上 |

也就是说：**本方案的持久化机制 = mainnet 的持久化机制**。LevelDB 的 WAL（write-ahead log）
保证每个 block 写完才 fsync 落盘，操作系统层突然断电（kernel panic / 拔电源）也只丢
mempool 内存里**还没打包**的 tx。已 commit 的 block 和 state 永远在。

业内同样架构的生产案例：早期 BSC、xDai/Gnosis Chain、Polygon Edge、各种企业链。

### 为什么用 Clique 而不是 reth dev / PoS

- **Clique** = 简单、可控、生产级实现、单/多 validator 都行；这条链给 dev/staging 用，
  完全够。未来要扩 validator 也只是改 extraData，不需要换技术栈。
- **reth dev** = single-node instant-seal，多节点支持弱。
- **PoS** = 必须配套 consensus client（lighthouse / prysm），运维复杂 5x，
  且 PoS dev 链没有现成方便的 single-validator 模板。

### 为什么 cancun fork 没启用（只到 shanghai）

**geth `v1.13.15` 的 Clique sealer 不兼容 cancun 的 blob 字段**，启动后 miner
会 `panic: unexpected excess blob gas value in clique`，整个进程崩溃重启循环。

原因：cancun 之后每个 block header 都带 `excessBlobGas` / `blobGasUsed` 这两个
EIP-4844 字段，但 blob 需要 beacon chain 提供 KZG 承诺，Clique 没 beacon chain，
geth 内部的 Clique seal 路径不处理这俩字段直接 panic。

genesis.json 里**只启用到 `shanghaiTime: 0`，不启用 `cancunTime`**。OP Stack 合约
部署只需要 shanghai (PUSH0)，cancun 的特性（blob、4788 BeaconRoots、5656 MCOPY 等）
都不必须。op-batcher 后续也走 calldata 模式不发 blob，跟这条 L1 的能力对齐。

---

## 2. 给运维：要开放的端口

**生产推荐方案（已经在配置里 hardcode 为默认）**：全部对外流量走 nginx + HTTPS，
docker 端口只 bind 在 `127.0.0.1`，安全组里只开 3 个端口。

### 安全组 / 防火墙（AWS SG / 云厂商防火墙 / `ufw` 都同理）

| 端口 | 协议 | 源 | 用途 | 必须？ |
|---|---|---|---|---|
| **22** | TCP | 运维 IP 白名单 | SSH | ✅ |
| **80** | TCP | `0.0.0.0/0` | Let's Encrypt HTTP-01 验证 + HTTPS 跳转 | ✅ |
| **443** | TCP | `0.0.0.0/0` | 浏览器 + RPC，全走 HTTPS | ✅ |

### 完全不需要对公网开放的端口（已经 bind 在 `127.0.0.1`）

| 端口 | 内部用途 |
|---|---|
| 8545 | L1 geth HTTP RPC（nginx 反代到 `/rpc`） |
| 8546 | L1 geth WebSocket（nginx 反代到 `/ws`） |
| 3001 | Blockscout frontend（nginx 反代到 `/`） |
| 4001 | Blockscout backend + WS（nginx 反代到 `/api/` 和 `/socket/`） |
| 8081 | Blockscout stats（nginx 反代到 `/stats-api/`） |
| 30303 | geth P2P（已设 `nodiscover + maxpeers=0`，根本不出网） |
| 5432 / 6379 | Postgres / Redis（只在 docker 内部网络） |

### 域名解析（运维在 DNS 控制台）

```
devl1.example.com   A   <服务器外网 IP>
```

如果走 Cloudflare 代理，记得**关 Cloudflare 的 WebSocket 强制 keepalive 限制**
（默认 100 秒）：Cloudflare → Network → WebSockets 打开即可，免费版也支持。

### nginx 反代（5 分钟搞定）

我已经写好现成的配置：[`nginx/devl1.example.com.conf`](nginx/devl1.example.com.conf)

```bash
# 1) 装 nginx + certbot（如未装）
sudo apt install -y nginx certbot python3-certbot-nginx

# 2) 部署配置
sudo cp dev/l1/nginx/devl1.example.com.conf /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/devl1.example.com.conf \
           /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# 3) 申请 Let's Encrypt 证书（domain 必须已经解析到本机）
sudo certbot --nginx -d devl1.example.com

# 4) 续期 cron certbot 默认装好了，验证一下：
sudo systemctl status certbot.timer
```

### 部署完成后用户访问入口

| 入口 | URL | 给谁用 |
|---|---|---|
| 浏览器 | `https://devl1.example.com` | 所有人 |
| RPC HTTPS | `https://devl1.example.com/rpc` | 钱包 / Foundry / op-deployer |
| RPC WSS | `wss://devl1.example.com/ws` | dapp / 订阅 newHeads / logs |
| API | `https://devl1.example.com/api/v2/blocks` | 监控脚本 / 第三方集成 |

### 如果想 dev 阶段方便直连（不走反代）

把 `.env` 改 `BIND_HOST=0.0.0.0`，运维额外开 `8545/8546/3001/4001/8081` 这 5 个端口
到公网。但**这就丢了 HTTPS**，浏览器会在 console 里报一堆 Mixed Content 警告，
不推荐生产用。

---

## 3. 服务器一键部署（新机器从零到出块）

> 新服务器 Ubuntu 22.04+。

### 3.1 安装依赖

`docker` 用 docker 官方源（`docker-ce`），**不要装 Ubuntu 自带的 `docker.io`**
（包名跟 `containerd` 撞，已经装过官方源的话 apt 会报 `containerd.io: Conflicts: containerd`）。

```bash
# 通用工具（任何情况都装）
sudo apt update
sudo apt install -y git make jq gettext-base curl python3

# Docker：已经能跑就跳过，否则装官方源版本
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  echo "✅ docker + compose 已就绪：$(docker --version)"
else
  # 加 docker 官方仓库
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# 让当前用户免 sudo 用 docker
sudo usermod -aG docker $USER
# 立即生效（不用退出登录）
newgrp docker
docker ps   # 不报错就 OK
```

### 3.2 拉代码 + 配置

```bash
git clone <YOUR_REPO_URL> mychain
cd mychain
git checkout feat/high-tps-flashblocks

cd dev/l1
cp .env.example .env
vim .env
# 必改：
#   PUBLIC_HOST=<本机外网 IP 或域名>
#   VALIDATOR_PASSWORD=<强随机串，可用 openssl rand -hex 32 生成>
# 默认值（已配好，按需调整）：
#   BS_PUBLIC_URL=https://devl1.example.com   ← 浏览器域名
#   BIND_HOST=127.0.0.1                       ← 端口只本机可达，走 nginx 反代
```

### 3.3 启动 L1 + 浏览器

```bash
make init                  # 一次性：生成 validator + genesis + geth init
make up                    # 启动 L1
make status                # 看 Block# 涨没涨
sleep 6 && make status     # 再看一次，应该 +3 左右

make blockscout-up         # 启动浏览器（首次约 1-2 分钟）
```

成功标志：

```
Client        : Geth/v1.13.15-...
Chain ID      : 901
Block #       : 3    ← 等 6 秒再看，应该变成 6/7/8
Clique signer : 0xXXXX...
Genesis hash  : 0xYYYY...
Validator     : 0xXXXX... balance: 10000.0000 ETH
```

---

## 4. 区块浏览器（Blockscout）

跟 L1 同一套 `make` 入口管理，但容器、network、volume 全独立。
**先确保 L1 已经 `make up` 跑起来**，再启动 Blockscout：

```bash
# 1) 确认 .env 里设了 PUBLIC_HOST（前面 L1 配过就行）
# 2) 启动（7 个容器：db / redis / backend / frontend / verifier / stats-db / stats）
make blockscout-up

# 3) 浏览器打开
#    http://<PUBLIC_HOST>:3001       (frontend)
#    http://<PUBLIC_HOST>:4001/api/  (backend API)

# 想看进度
make blockscout-logs
make blockscout-ps
```

**首次启动**会跑 DB 迁移 + 从 block 0 索引整条 L1，dev 链 1-3 分钟就追平。
之后 backend 实时跟链头，新出的 block 几百毫秒内进浏览器。

### 想绑域名走 HTTPS（生产推荐）

`.env` 设：

```bash
BS_PUBLIC_URL=https://l1.example.com
```

然后 `make blockscout-up`，脚本最后会打印 nginx 反代示例配置，把 5 行 `location`
段贴进现有 nginx 即可。WebSocket 实时推送（Phoenix `/socket/`）的 `Upgrade` /
`Connection` 头一定要加，不然首页 tx 列表不刷新。

### Blockscout 跟 L1 解耦

- L1 数据在 `mychain-l1-geth-data` volume，Blockscout 数据在 `mychain-l1-bs-*` 三个 volume
- `make blockscout-clean` 只清浏览器，不动链
- `make clean` 只清链，不动浏览器（但浏览器会看到链没了）
- 想换 L1 实现（比如换 reth）也不影响浏览器，只要 RPC 兼容就行

---

## 5. 客户连接（MetaMask / Foundry）

### MetaMask 添加网络

| 字段 | 值（生产 / HTTPS 模式） | 值（dev / 直连模式） |
|---|---|---|
| Network Name | mychain-l1-dev | mychain-l1-dev |
| RPC URL | `https://devl1.example.com/rpc` | `http://<PUBLIC_HOST>:8545` |
| Chain ID | 901 | 901 |
| Currency Symbol | ETH | ETH |
| Block Explorer | `https://devl1.example.com` | — |

钱包想拿测试 ETH，导入你自己的 dev 助记词（在 `.env` 的 `ANVIL_MNEMONIC` 里配置）：

```
<在此填入你的 dev 助记词，不要入仓真实助记词>
```

前 10 个派生账号各有 10000 ETH，私钥也可以直接 import。

### Foundry cast 测试

```bash
export RPC=https://devl1.example.com/rpc
# 余额（换成你 dev 助记词派生的地址）
cast balance 0x<YOUR_DEV_ADDRESS> --rpc-url $RPC
# 当前 block
cast block-number --rpc-url $RPC
# 发一笔 tx（换成你 dev 助记词派生的私钥/地址）
cast send --rpc-url $RPC \
  --private-key 0x<YOUR_DEV_PRIVATE_KEY> \
  --value 1ether 0x<RECIPIENT_ADDRESS>
```

或者直接用 `make fund`：

```bash
make fund TO=0x<RECIPIENT_ADDRESS>
make fund TO=0xabcdef... AMOUNT=500
```

---

## 6. 持久化与恢复测试

### 重启 docker 不丢数据

```bash
docker compose down
docker compose up -d geth-l1
make status
# 出块号会从上次停止的点继续涨（不会归零）
```

### 模拟服务器断电

```bash
sudo systemctl kill -s SIGKILL docker
sudo systemctl start docker
docker start mychain-l1-geth
make status
# block# 应该接上断电前 +1~2，没有 hash mismatch / state corruption
```

geth 的 LevelDB 用 fsync 写 WAL，断电最多丢 < 1 个 block 的内存 mempool，
**已上链的区块和 state 完全保留**。这是跟 anvil 最本质的区别。

### 备份链数据

```bash
# 冷备：完全停机再 cp（最安全）
make down
sudo cp -a /var/lib/docker/volumes/mychain-l1-geth-data/_data /backup/l1-snap-$(date +%F)
make up

# 热备：用 geth 的导出
docker exec mychain-l1-geth geth --datadir /data export /data/chain.dump 0 latest
docker cp mychain-l1-geth:/data/chain.dump /backup/l1-chain-$(date +%F).dump
```

冷备 200GB 链大概要 5-10 分钟；停机 5 分钟换 100% 数据完整性，值。
后续可接 cron + 增量同步 + S3 上传，这里不展开。

---

## 7. 故障排查

| 现象 | 排查 |
|---|---|
| `make up` 后 `make status` 报 "Connection refused" | 等 5-10 秒再试（geth 启动需要解 keystore）；还不行 `make logs` 看报错 |
| 启动报 `Failed to unlock account` | 检查 `secrets/password.txt` 跟 `.env` 的 `VALIDATOR_PASSWORD` 一致 |
| 出块号一直是 0 不涨 | 必是 `--mine` 没生效 → `make logs` 看是否有 "Sealing paused, waiting for transactions"（Clique 配 `period > 0` 不该出现这条）；检查 `VALIDATOR_ADDRESS` 是否对 |
| `make init` 报 `database already contains an incompatible genesis block` | volume 里有旧链。**确认要丢数据**后 `make clean` 重来 |
| `make init` keystore 文件 owner 是 root | 脚本会自动 chown；若失败手动 `sudo chown -R $USER:$USER keystore` |
| 端口冲突 | 改 `.env` 的 `HTTP_PORT` / `WS_PORT` / `P2P_PORT`，再 `make restart` |
| `make blockscout-up` 报 "network mychain-l1-net 不存在" | 先 `make up` 把 L1 起来再启浏览器 |
| Blockscout 首页一直 "loading"，块号不动 | `make blockscout-logs` 看 backend；常见原因是 backend 还在追历史 block（首次需要 1-3 分钟），等就行 |
| Blockscout 实时数据不刷新（要 F5） | Phoenix WS 被反代屏蔽。检查 nginx `/socket/` 段是否带 `Upgrade` / `Connection` header |

---

## 8. 安全提醒

- `keystore/UTC--*` 是 validator 私钥的加密 keystore，**绝不能 commit**（`.gitignore` 已护）。
- `secrets/password.txt` 含 keystore 密码，**绝不能 commit**。
- `.env` 含密码明文，**绝不能 commit**。
- 当前配置开了 `--allow-insecure-unlock` + `personal_*` API：HTTP RPC 任何人都能用
  `personal_unlockAccount` 试解锁。**只允许内网 RPC**，要对外公开 RPC 必须：
  - 删 `--allow-insecure-unlock` 和 `--unlock`
  - 改 `--http.api` 去掉 `personal,admin,miner,clique`
  - validator 用 [clef](https://geth.ethereum.org/docs/tools/clef/introduction) 离线签名

---

## 9. 接入 L2（路线图，不在本次范围）

L1 稳定跑 ≥1 天后再做：

1. 改 `dev/.env`：`L1_RPC_URL_INTERNAL` 从 `http://anvil:8545` 改成 `http://<host_gateway>:8545`
   （docker host_gateway 指向本机 L1 容器，需要给 op-* 服务加 `extra_hosts`）
2. op-deployer 的 `intent.toml` 把 L1 chainID 设成 901
3. op-batcher 必须 `DATA_AVAILABILITY_TYPE=calldata`（不发 blob，因为我们 L1 没 beacon）
4. 重跑 `make deploy-l1 deploy-genesis init-geth l2-up`
5. 用 validator 给 OP Stack 角色账号（DEPLOYER / BATCHER / PROPOSER）转 ETH
   做 gas
