# RESTART_TEST_PLAN_V7.md — v7 (Flashblocks) 各种重启场景影响测试

> **状态**: 测试计划（draft），按本文档跑完一轮后把结果回填到 §10 报告区
> **范围**: mychain v7 (Phase 2 Flashblocks) **生产形态**部署：
>   - **L1 机**（chain-l1-test）：独立 geth Clique（`dev/l1/`），不是 anvil
>   - **L2 机**（chain-test2）：v7 stack（v6 OP Stack + 3 个 Flashblocks 容器 + l1-proxy）
>   - **Blockscout 机**（独立）：`dev/blockscout-standalone/`
> **关联**: `PHASE2_INTEGRATION.md`、`PHASE2_BUNDLE_PROXY.md`、`STRESS_TEST_REPORT_V7.md`、`dev/l1/README.md`
> **前置**: `make dev-up-flashblocks` 已成功，`make flashblocks-smoke` 9/9 通过；L1 机 `make up` 出块正常
> **不在范围**:
>   - v6 baseline 重启测试（单独 `RESTART_TEST_PLAN_V6.md`，TODO）
>   - anvil 模式（dev/PR 验证才用，不是生产形态；本文档不专门覆盖）

---

## 0. 摘要

### 0.1 跨机部署的核心要点

生产 v7 是**三机部署**，重启风险按机器分组：

```
┌─────────────────────┐   RPC ${PUBLIC_L1}:8545    ┌──────────────────────────────────┐
│ L1 机                │ ◀──────────────────────── │ L2 机                             │
│  mychain-l1-geth     │                           │  l1-proxy        :8546（容器内）  │
│  (Clique PoA单签)    │                           │   ↑ UPSTREAM=PUBLIC_L1:8545      │
│  LevelDB 持久化      │                           │   ↑                              │
│  block_time=2s       │                           │  op-node / op-batcher / op-...   │
└─────────────────────┘                            │  op-rbuilder / rollup-boost      │
                                                   │  bundle-proxy :9560 ← dApp 入口  │
                                                   └──────────────────────────────────┘
                                                                  ▲
                                                       RPC :9545  │
                                                   ┌──────────────┴────────┐
                                                   │ Blockscout 机          │
                                                   │  dev/blockscout-       │
                                                   │   standalone/ (8 容器) │
                                                   └───────────────────────┘
```

### 0.2 核心结论（写在最前面，节省同事时间）

| # | 结论 | 来源 |
|---|---|---|
| C1 | **L1 (独立 geth) 重启不丢已上链 block**（LevelDB + WAL，最多丢 mempool 内 < 2s 的未打包 tx） | `dev/l1/README.md` §6 已断言 |
| C2 | **L1 短暂停（< 30s）L2 完全无感**：op-node `sequencer.l1-confs=2` + `verifier.l1-confs=2` 给了 ~6s 容忍窗口；超过会暂停 derive 但不影响 sequencer 出 unsafe block | OP Stack 设计 |
| C3 | **L1 长时间停（> 30s）L2 仍出 unsafe block，但 safe head 不再涨**（op-batcher 提不上去）；L1 一恢复，safe 在 60s 内追上 | op-batcher poll-interval=2s |
| C4 | **`rollup-boost` 是 v7 唯一停链单点**（不是 L1，因为 L1 短停 L2 仍出 unsafe；rollup-boost 一停连 unsafe 都停） | `flashblocks-chaos.sh` 场景 4 已验证 |
| C5 | **`l1-proxy` 重启 ~3s 内 op-batcher 报错重试，无业务影响**；但若 `l1-proxy` 跟 upstream 长时间不通，effect 等价于 C3 | commit `04034c2` |
| C6 | **op-rbuilder restart 不影响链**，bundle-proxy 会自动 fallback 到 op-geth | `flashblocks-chaos.sh` 场景 1 |
| C7 | **bundle-proxy restart ~5s 内 dApp 收 503**，链不受影响 | proxy 启动时间 |
| C8 | **op-node 启动时 rollup-boost 必须已 healthy**，否则卡 `Waiting for L2 engine` 死循环 | `dev-up-flashblocks-naive` 反例 |
| C9 | **重启顺序错了能用 `make flashblocks-recover` 一键修** | Makefile target |
| C10 | **L1 + L2 同时挂时起来顺序**：必须先起 L1，等 head 涨 ≥ 5；再起 L2，等 boost healthy 后起 op-node | OP Stack derive 依赖 L1 |

---

## 1. v7 拓扑速览（重启依赖分析用）

### 1.1 跨机拓扑（生产形态）

```
┌─────────── 机器 A：L1 机（chain-l1-test）─────────────┐
│  mychain-l1-geth                                       │
│   geth v1.13.15 + Clique PoA 单签                       │
│   LevelDB archive 全历史 state                          │
│   port 8545 (HTTP) / 8546 (WS)                          │
│   network: mychain-l1-net                               │
│   volume: mychain-l1-geth-data                          │
└─────────────────────────────────────────────────────────┘
                          ▲
                          │  HTTP :8545
                          │
┌─────────── 机器 B：L2 机（chain-test2）────────────────┐
│   l1-proxy   :8546（容器内）                            │
│    intercepts eth_blobBaseFee → 0x1                     │
│    其他 RPC 透传 to ${L1_PROXY_UPSTREAM}               │
│        │                                                │
│        │ http://l1-proxy:8546                           │
│        ▼                                                │
│   op-node   → op-batcher                                │
│        │ engine API (JWT)                               │
│        ▼                                                │
│   rollup-boost :8081                                    │
│    dispatcher，分发 FCU/newPayload 给                   │
│    op-geth(:8551) + op-rbuilder(:9551)                  │
│        │                                                │
│   ┌────┴───────┐                                        │
│   ▼            ▼                                        │
│   op-geth   op-rbuilder    ◀── bundle-proxy :9560      │
│   :9545     :9550                ▲                      │
│   (sequencer EL)                 │ eth_sendBundle      │
│   (fallback target)              │                      │
│   network: mychain-dev                                  │
└─────────────────────────────────────────────────────────┘
                          ▲
                          │ HTTP :9545 / WS :9546
                          │
┌─────────── 机器 C：Blockscout 机（独立）───────────────┐
│   8 容器 standalone Blockscout                          │
│   indexer 指 L2 机的 :9545                              │
└─────────────────────────────────────────────────────────┘
```

### 1.2 容器依赖矩阵（行 = 谁挂了，列 = 谁受影响）

| ↓ 挂 \ 影响 → | L1 (mychain-l1-geth) | l1-proxy | op-geth | op-rbuilder | rollup-boost | op-node | op-batcher | bundle-proxy | Blockscout |
|---|---|---|---|---|---|---|---|---|---|
| **L1 (geth Clique)** | — | ⚠️ proxy 自身仍 healthy（设计如此），upstream 不通 | ✅ 短停无感 | ✅ | ✅ | ⚠️ derive 暂停 > 30s 后 | ❌ 无新 L1 block 可 post | ✅ 写能进 mempool | ⚠️ index 滞后 |
| **l1-proxy** | ✅ | — | ✅ | ✅ | ✅ | ❌ derive 暂停 | ❌ 同上 | ✅ | ✅ |
| **op-geth** | ✅ | ✅ | — | ⚠️ engine 上游缺一路（rollup-boost 仍可 dispatch 给 rbuilder） | ⚠️ 同左 | ❌ engine FCU 失败 | ❌ rpc 拉 state 失败 | ⚠️ fallback 也失败 | ❌ 不能 index |
| **op-rbuilder** | ✅ | ✅ | ✅ | — | ✅ 仍能用 op-geth 单路 | ✅ | ✅ | ⚠️ 熔断 fallback 到 op-geth | ✅ |
| **rollup-boost** | ✅ | ✅ | ✅ | ✅ | — | ❌ **engine 断**，sequencer 停 | ⚠️ rollup-rpc 还在但无新块 | ⚠️ 写能收但不上链 | ⚠️ 滞后 |
| **op-node** | ✅ | ✅ | ✅ | ✅ | ✅ | — | ❌ rollup-rpc 断 | ✅ 写还能进 rbuilder mempool | ⚠️ 滞后 |
| **op-batcher** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — | ✅ | ⚠️ safe head 不动但 unsafe 不影响 |
| **bundle-proxy** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — | ✅ |
| **Blockscout** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |

---

## 2. 测试目标与判定标准

### 2.1 必须满足（PASS 条件，不变量 I1-I10）

| # | 不变量 | 验证方法 |
|---|---|---|
| I1 | **L1 chainId 不变** | `cast chain-id --rpc-url ${PUBLIC_L1}:8545` 重启前后一致 |
| I2 | **L1 genesis hash 不变** | `cast block 0 --json` 的 `hash` 字段重启前后一致 |
| I3 | **L1 head 单调增** | 重启窗口内允许暂停 < 2 \* block_time = 4s，恢复后必须接上原值；**绝对不能从 0 起步**（说明 LevelDB 损坏 / 误清 volume） |
| I4 | **L2 chainId 不变** | `cast chain-id --rpc-url ${PUBLIC_HOST}:9545 == :9550 == :9555 == :9560`，且重启前后一致 |
| I5 | **L2 genesis hash 不变** | 同 I2 但用 L2 RPC |
| I6 | **L2 unsafe head 单调增** | 重启窗口内允许暂停，恢复后从断点继续，无 reorg |
| I7 | **L2 safe head 最终恢复增长** | 重启后 ≤ 180s 内 `optimism_syncStatus.safe_l2.number` 开始涨（独立 L1 模式给 180s buffer，比 anvil 模式宽松） |
| I8 | **历史 tx 仍可查** | 重启前记录的一笔 L1 tx + 一笔 L2 tx，重启后 `eth_getTransactionReceipt` 仍返结果 |
| I9 | **客户端 RPC URL 不变** | dApp 仍走 bundle-proxy :9560；钱包仍连 L1 公网域名（如 https://devl1.example.com/rpc） |
| I10 | **bundle-proxy 熔断器恢复** | `curl :9560/status` 的 `circuit` 字段 = `closed` |

### 2.2 禁止出现（FAIL 条件，任一即不通过）

- ❌ L1 head 倒退 / 从 0 起步（**最严重，意味着丢链**）
- ❌ L2 head 倒退
- ❌ `optimism_syncStatus` 卡某个高度 > 5 min
- ❌ op-node 日志出现 `genesis hash mismatch` / `L1 chain has reset` / `unsafe head rewind`
- ❌ op-rbuilder 日志出现 `state root mismatch` / `parent hash unknown`
- ❌ bundle-proxy `/metrics` 的 `bundle_proxy_rpc_total{outcome="both_failed"}` 增长（说明 rbuilder + fallback 都挂）
- ❌ rollup-boost 重启后 op-node 卡 `Waiting for L2 engine` > 60s（必须 `flashblocks-recover`）
- ❌ rbuilder-data 卷损坏 / 自动重建（应该只在显式 `flashblocks-clean` 时才会发生）
- ❌ L1 重启后 op-batcher 持续报 `unknown method eth_blobBaseFee` 不退（说明 l1-proxy 拦截失效）

---

## 3. 测试矩阵

### 3.1 重启等级（按破坏性由弱到强）

| Lv | 操作 | 用例代号 |
|---|---|---|
| L1 | `docker compose restart <svc>` | V7-Rxx |
| L2 | `docker stop && docker start <svc>` | V7-Sxx |
| L3 | `docker compose rm -fs <svc> && up -d <svc>` | V7-Cxx |
| L4 | `make flashblocks-down && make flashblocks-up` | V7-Fxx |
| L5 | `systemctl restart docker` | V7-Dxx |
| L6 | `sudo reboot`（正常）| V7-Bxx |
| L7 | hard reset（断电模拟）`echo b > /proc/sysrq-trigger` | V7-Hxx |
| L8 | **跨机故障**（网络分区 / L1 机宕机 / L2 机宕机）| V7-Xxx |

### 3.2 用例总数与时间预算

| 阶段 | 用例数 | 预计时间 |
|---|---|---|
| §6 单容器 restart / 重建 | 12 | 2.5h |
| §7 组合场景（多容器联动）| 6 | 1.5h |
| §8 启动顺序 + recover | 4 | 1h |
| §9.1 L2 机 daemon / reboot / hard reset | 4 | 2h（含观察期）|
| §9.2 L1 机 daemon / reboot / hard reset | 4 | 2h |
| §9.3 跨机故障 / 网络分区 | 5 | 2h |
| §9.4 Blockscout 机重启 | 3 | 1h |
| §11 已知坑回归 | 8 | 1h |
| **合计** | **46** | **~13h ≈ 1.5-2 工作日** |

---

## 4. 工具准备

### 4.1 不变量快照脚本（v7 跨机版）

测试前后必跑，diff 出问题。**比 v6 多查 l1-proxy + L1 跨机 RPC**。

```bash
# /tmp/v7-snapshot.sh （L2 机上跑）
#!/usr/bin/env bash
set -u
cd /path/to/mychain  # 改成实际路径
source dev/.env >/dev/null 2>&1 || true
source dev/.env.flashblocks >/dev/null 2>&1 || true

# L1 机 RPC（公网域名 / IP）
RPC_L1_EXTERNAL="${RPC_L1_EXTERNAL:-${L1_RPC_URL_EXTERNAL:-http://l1-host:8545}}"
# l1-proxy 在 L2 机的对外端口（如果暴露了）；没暴露就走容器内
PROXY_VIA_DOCKER=1

# L2 机本地 RPC
H="${SMOKE_HOST:-127.0.0.1}"
RPC_GETH="http://${H}:${L2_RPC_PORT:-9545}"
RPC_RBUILDER="http://${H}:${OP_RBUILDER_PORT:-9550}"
RPC_BOOST="http://${H}:${ROLLUP_BOOST_PORT:-9555}"
RPC_PROXY="http://${H}:${BUNDLE_PROXY_PORT:-9560}"
RPC_OPNODE="http://${H}:${OP_NODE_RPC_PORT:-9547}"

rpc() { curl -s --max-time 3 -X POST "$1" -H 'content-type: application/json' -d "$2" 2>/dev/null; }
bn()  { rpc "$1" '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq -r '.result // "ERR"'; }
cid() { rpc "$1" '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' | jq -r '.result // "ERR"'; }
ghash() { rpc "$1" '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' | jq -r '.result.hash // "ERR"'; }

echo "=== $(date -Iseconds) ==="
echo "── L1（独立 geth Clique）─────────"
printf "  external head     %s\n"   "$(bn  $RPC_L1_EXTERNAL)"
printf "  external chainId  %s\n"   "$(cid $RPC_L1_EXTERNAL)"
printf "  external genesis  %s\n"   "$(ghash $RPC_L1_EXTERNAL)"

echo ""
echo "── L2 各 RPC 一致性 ─────────────"
printf "  unsafe (op-geth)     %s\n"  "$(bn  $RPC_GETH)"
printf "  unsafe (op-rbuilder) %s\n"  "$(bn  $RPC_RBUILDER)"
printf "  unsafe (rollup-boost)%s\n"  "$(bn  $RPC_BOOST)"
printf "  unsafe (bundle-proxy)%s\n"  "$(bn  $RPC_PROXY)"
printf "  L2 chainId (geth)    %s\n"  "$(cid $RPC_GETH)"
printf "  L2 genesis (geth)    %s\n"  "$(ghash $RPC_GETH)"

echo ""
echo "── op-node syncStatus ───────────"
rpc "$RPC_OPNODE" '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
  | jq -r '.result | "  safe=\(.safe_l2.number)  finalized=\(.finalized_l2.number)  head_l1=\(.head_l1.number)  seen_l1=\(.current_l1.number)"' 2>/dev/null || echo "  ❌ op-node 不可达"

echo ""
echo "── bundle-proxy /status ────────"
curl -s --max-time 3 "$RPC_PROXY/status" \
  | jq -r '{circuit, inflight, head: .head.number, fallback_enabled}' 2>/dev/null || echo "  ❌ proxy 不可达"

echo ""
echo "── L2 机容器健康 ───────────────"
for c in mychain-op-geth mychain-op-rbuilder mychain-rollup-boost \
         mychain-op-node mychain-op-batcher mychain-bundle-proxy l1-proxy; do
  st=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}—{{end}}' "$c" 2>/dev/null || echo "missing|—")
  printf "  %-26s %s\n" "$c" "$st"
done

echo ""
echo "── L1 机容器健康（需要从 L1 机跑或 ssh 拿）"
echo "  ssh \$L1_HOST 'docker inspect -f \"{{.State.Status}}|{{.State.Health.Status}}\" mychain-l1-geth'"
```

### 4.2 head 持续监控（开 3 个 tmux 窗口同时盯）

```bash
# 窗 1：L1 head （从 L2 机经 proxy）
watch -n 1 'docker exec l1-proxy python3 -c "
import urllib.request as u, json
r=u.urlopen(u.Request(\"http://127.0.0.1:8546\",
  data=b\"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"method\\\":\\\"eth_blockNumber\\\",\\\"params\\\":[],\\\"id\\\":1}\",
  headers={\"Content-Type\":\"application/json\"}),timeout=3).read()
print(json.loads(r)[\"result\"])"; date +%T'

# 窗 2：L2 unsafe head（通过 bundle-proxy）
watch -n 1 'curl -s -X POST http://127.0.0.1:9560 -H "content-type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}" \
  | jq -r ".result"; date +%T'

# 窗 3：L2 safe head（通过 op-node）
watch -n 2 'curl -s -X POST http://127.0.0.1:9547 -H "content-type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"optimism_syncStatus\",\"params\":[],\"id\":1}" \
  | jq -r ".result | \"safe=\(.safe_l2.number)  head_l1=\(.head_l1.number)\""; date +%T'
```

### 4.3 重启前必须记录的"位置点"

```bash
# /tmp/v7-pre-restart.env
# L1
L1_HEAD=$(cast block-number --rpc-url $L1_RPC)
L1_BENCHMARK_TX=$(cast block latest --rpc-url $L1_RPC --json | jq -r '.transactions[0] // empty')
# L2
L2_HEAD=$(cast block-number --rpc-url http://127.0.0.1:9545)
L2_BENCHMARK_TX=$(cast block latest --rpc-url http://127.0.0.1:9545 --json | jq -r '.transactions[0]')
# 余额（用 L1 validator + L2 deployer）
L1_VAL_BAL=$(cast balance $VALIDATOR_ADDRESS --rpc-url $L1_RPC)
L2_DEP_BAL=$(cast balance $DEPLOYER_ADDRESS --rpc-url http://127.0.0.1:9545)
```

### 4.4 背景 tx 流量（验证 mempool / 入流量行为）

```bash
make bot-token-spam-up TARGET_TPS=50  # 低强度持续打 L2
# L1 不需要专门压力，Clique 即使没 tx 也定时出空块
```

---

## 5. 测试流程（每个用例都按这 6 步走）

```
1. 快照前：bash /tmp/v7-snapshot.sh > /tmp/snap-before.txt
2. 记录位置点：source /tmp/v7-pre-restart.env (从 §4.3 脚本生成)
3. 启动 3 个 head watcher（独立 tmux）
4. 执行操作（restart / down+up / kill / 跨机网络分区 等）
5. 快照后 + 验证：
   - bash /tmp/v7-snapshot.sh > /tmp/snap-after.txt
   - diff -u /tmp/snap-before.txt /tmp/snap-after.txt
   - cast tx $L1_BENCHMARK_TX --rpc-url $L1_RPC   # 必须返回 receipt
   - cast tx $L2_BENCHMARK_TX --rpc-url http://127.0.0.1:9545
   - cast balance $DEPLOYER_ADDRESS --rpc-url http://127.0.0.1:9545  # 跟 L2_DEP_BAL 对比
   - make flashblocks-smoke  # 9/9 必须通过
6. 填写 §10 报告表的一行
```

---

## 6. 单容器 restart / 重建

> 优先级：✅ 必跑（生产相关）、⚠️ 应跑（已知风险点回归）、🧪 选做（探索）

### 6.1 L2 机容器（L1/L2/L3 等级）

| # | 用例 | 操作（在 L2 机） | 预期 | 优先级 |
|---|---|---|---|---|
| V7-R01 | **l1-proxy restart** | `docker compose --env-file .env restart l1-proxy` | proxy 自身 ~3s 内 healthy；期间 op-batcher 报 1-2 次 `will retry`，恢复后无残留 | ✅ |
| V7-R02 | op-geth restart | `docker compose restart op-geth` | rollup-boost 一路 dispatch 失败但 op-rbuilder 单路仍可；op-geth 起来后追到 head；mempool 清空 | ✅ |
| V7-R03 | op-rbuilder restart | `docker compose restart op-rbuilder` | bundle-proxy 触发熔断 → fallback 到 op-geth；rbuilder 起来后 ~10s 熔断器 reset；rbuilder 从 rbuilder-data 卷接上 head | ✅ |
| V7-R04 | rollup-boost restart | `docker compose restart rollup-boost` | **链出块停 ~15s**（op-node 重连 engine API）；之后恢复；safe head 滞后 ~30s 恢复 | ✅ |
| V7-R05 | op-node restart | `docker compose restart op-node` | engine FCU 暂停 ~10s；op-node 起来后从 rollup-boost 重新拿 head，继续 sequence | ✅ |
| V7-R06 | op-batcher restart | `docker compose restart op-batcher` | unsafe head 不受影响；safe head 暂停后恢复 | ✅ |
| V7-R07 | bundle-proxy restart | `make flashblocks-restart-proxy` | dApp 5xx ~5s；链不受影响；`/status` circuit=closed | ✅ |
| V7-C01 | op-rbuilder rm+up（保留 volume） | `docker compose rm -fs op-rbuilder && docker compose -f docker-compose.yml -f docker-compose.flashblocks.yml up -d op-rbuilder` | 新容器拿同样的 rbuilder-data → 接上 head | ⚠️ |
| V7-C02 | rollup-boost rm+up | 同上替换为 rollup-boost | rollup-boost 无状态，纯重建无影响；op-node 重连 | ⚠️ |
| V7-C03 | op-geth rm+up（保留 opgeth-data 卷） | 关键回归 | 必须接上 head；不能从 genesis re-init | ✅ |
| V7-C04 | op-rbuilder rm+up + 清 rbuilder-data 卷 | `docker volume rm dev_rbuilder-data` | rbuilder 从 genesis 重新 sync state（可能数小时）；期间 bundle-proxy 全 fallback 到 op-geth；**演练但不在生产做** | 🧪 |

**重点观察项**：
- V7-R01 后看 `docker logs mychain-op-batcher --tail=20` 应有 `will retry` 但不超过 3 次
- V7-R03 后 `bundle_proxy_rpc_total{outcome="rbuilder_fail_fallback_ok"}` 必须 > 0
- V7-R04 后 op-node 日志不能出现 `Waiting for L2 engine` > 30s
- V7-R02 后 rollup-boost 日志应有 `forwarded to builder only` 或类似

### 6.2 L1 机容器（独立 L1 节点 restart）

> **必须 SSH 到 L1 机执行**。L1 跟 L2 解耦，操作纯走 `dev/l1/Makefile`。

| # | 用例 | 操作（在 L1 机） | 预期 | 优先级 |
|---|---|---|---|---|
| V7-R08 | L1 geth restart（最快） | `cd dev/l1 && docker compose --env-file .env restart geth-l1` | L1 出块暂停 ~5s；恢复后接上原 head（不归零） | ✅ |
| V7-R09 | L1 down + up（容器重建） | `cd dev/l1 && make down && make up` | 同 V7-R08；额外验证 `mychain-l1-geth-data` volume 持久化 | ✅ |
| V7-R10 | L1 节点重启时 L2 端观察 | V7-R08 期间在 L2 机跑 §4.2 head watcher | L2 unsafe head **不受影响**（按 1s 继续涨）；L2 safe head 暂停 ~10s 后恢复涨；op-batcher 日志短暂报 RPC 重试 | ✅ |

---

## 7. 组合场景（多容器联动）

| # | 用例 | 操作 | 预期 | 优先级 |
|---|---|---|---|---|
| V7-G01 | op-rbuilder + bundle-proxy 同时挂 | 两个 `docker stop` 同时执行 | dApp 写 100% 失败；链继续出块（op-geth 单路）；起来顺序：rbuilder → bundle-proxy → 测试写恢复 | ✅ |
| V7-G02 | rollup-boost + op-node 同时挂 | 两个同停 | 链停摆；起来顺序必须 boost → op-node（用 `flashblocks-recover` 自动处理） | ✅ |
| V7-G03 | op-geth + op-rbuilder 同时挂 | 两个同停 | engine API 双路全断，rollup-boost 无 backend 可分发，链停；起来顺序：geth → rbuilder → 等 boost 重连 | ⚠️ |
| V7-G04 | l1-proxy + op-batcher 同时挂 | 两个同停 | safe head 长时间不动；其他不影响；起来后 safe 追上 | ⚠️ |
| V7-G05 | 全 v7 容器同时挂 | `make flashblocks-down`（不停 v6） | dApp 全断；L2 链停（op-node engine 断）；v6 主链 op-geth 自身仍可 RPC | ✅ |
| V7-G06 | L2 机全 stack 同时挂 | `make dev-down` | 全停（L1 机不受影响）；起来后 head 必须接上 | ✅ |

---

## 8. v7 stack 整体重启 + 启动顺序

> 这是 v7 的**最大坑**：`dev-up-flashblocks-naive` 老命名就是因为顺序错被打 legacy 标签。

| # | 用例 | 操作 | 预期 | 优先级 |
|---|---|---|---|---|
| V7-F01 | `make flashblocks-restart`（v7 三容器，不动 v6 主链）| down → up | 顺序：op-rbuilder → rollup-boost → bundle-proxy；op-node 在 down 期间继续连 op-geth 直连？**待验证** | ✅ |
| V7-F02 | `make flashblocks-clean`（清 rbuilder volume）+ flashblocks-up | 模拟"换 builder 镜像 + 清状态" | rbuilder 重新 sync；rollup-boost 在等期间所有 FCU 走 op-geth 单路；待 rbuilder 追上后双路恢复 | ⚠️ |
| V7-O01 | 错序启动复现 | `make dev-up-flashblocks-naive`（dev-up → flashblocks-up） | op-node 启动时 rollup-boost 还没起，op-node 日志卡 `Waiting for L2 engine`，超时也不自愈 | ✅ |
| V7-O02 | 用 recover 修复 V7-O01 | 在 V7-O01 卡住后跑 `make flashblocks-recover` | rm op-node/op-batcher → 确认 op-geth healthy → 起 boost → 起 op-node：成功恢复 | ✅ |
| V7-O03 | 正常启动顺序 | `make dev-up-flashblocks` | 按 deploy→op-geth→flashblocks→\_wait-rollup-boost→op-node 顺序，一次成功 | ✅ |
| V7-O04 | op-rbuilder 缺 jwt.txt 启动 | 故意删 `workdir/shared/jwt.txt` 后启动 | op-rbuilder panic / rollup-boost auth 失败；不能继续 | ⚠️ |

---

## 9. 整机重启 / 跨机故障

> **必须在测试环境跑**，生产先做镜像快照（云盘）再实施。

### 9.1 L2 机重启（L1 / Blockscout 不动）

| # | 用例 | 操作（L2 机） | 预期 | 优先级 |
|---|---|---|---|---|
| V7-D01 | L2 机 `systemctl restart docker` | `sudo systemctl restart docker` | 所有 `restart: unless-stopped` 容器自动起；启动顺序由 docker 决定，可能命中 V7-O01 顺序问题 → **若卡住跑 recover** | ✅ |
| V7-B01 | L2 机正常 reboot | `sudo reboot` | 同 V7-D01；额外验证开机后所有容器都 auto-start | ✅ |
| V7-H01 | L2 机 hard reset 模拟断电 | `sudo sync; echo b > /proc/sysrq-trigger`（云上先做卷快照）| op-geth LevelDB WAL 不丢已上链 block；rbuilder-data 卷可能需要 reload；L1 视角看 L2 batcher 暂停 → 恢复 | ✅ |
| V7-D02 | docker daemon OOM kill | `sudo kill -9 $(pgrep dockerd)` 然后等 systemd 拉起 | 看 daemon 是否能干净恢复 | 🧪 |

### 9.2 L1 机重启（L2 / Blockscout 不动）

> **核心新增章节**。L1 是独立机器，它的存活直接决定 L2 能不能提交 batch。

| # | 用例 | 操作（L1 机） | L2 端预期 | 优先级 |
|---|---|---|---|---|
| V7-LR1 | L1 机 `systemctl restart docker` | L1 机 `sudo systemctl restart docker` | L1 容器自动起；L2 unsafe head 继续；L2 safe head 暂停 ~30s 后恢复 | ✅ |
| V7-LR2 | L1 机正常 reboot | L1 机 `sudo reboot` | L2 unsafe 继续；L1 起来后 safe 在 60-120s 内追上；**L1 启动期间 L2 unsafe 头跟 safe 头距离会拉大到 100+ 块** | ✅ |
| V7-LR3 | **L1 机 hard reset（断电）** | L1 机 `sudo sync; echo b > /proc/sysrq-trigger` | **关键测试**：geth LevelDB + WAL 必须不丢已上链 block；L2 sequencer 不受影响；L1 起来后 L2 safe 追上 | ✅ |
| V7-LR4 | L1 机长停（30 min）后恢复 | L1 机 `make down`；30 min 后 `make up` | L2 unsafe 持续涨；safe head 完全不动；恢复后 op-batcher 一次性 post 30 min 积累的所有 batch；safe head 急速追赶 | ⚠️ |

**重点观察项**：
- V7-LR3 必须验 I3 (`L1 head 不能从 0 起步`)。若发现 L1 head 从 0 起步，L1 容器的 LevelDB 损坏或挂载错卷，**必须 stop everything 排查**。
- V7-LR4 看 L2 上是否仍能发 tx：理论上能（dApp → bundle-proxy → op-rbuilder mempool → 进 unsafe block），但**这些 tx 在 L1 恢复前都没有 safe / finalized 保证**，钱包侧 confirmations 数会一直是 0。

### 9.3 跨机故障 / 网络分区

> **生产形态特有**，单机部署的 v6 不会有这些场景。

| # | 用例 | 操作 | 预期 | 优先级 |
|---|---|---|---|---|
| V7-X01 | L1 ↔ L2 网络分区 | 在 L2 机 `sudo iptables -A OUTPUT -d ${L1_HOST_IP} -j DROP` | l1-proxy 自身 healthcheck 仍 pass（设计如此，proxy 不依赖 upstream），但 op-batcher/op-node 报 `dial tcp: i/o timeout` | ✅ |
| V7-X02 | 恢复 V7-X01 | `sudo iptables -D OUTPUT -d ${L1_HOST_IP} -j DROP` | 30s 内 derive/batcher 自动恢复，safe head 追上 | ✅ |
| V7-X03 | L1 + L2 同时 hard reset | 两机同时断电（必须有快照） | 起来顺序：**L1 先**（等 head 涨 ≥ 5）→ L2（按 V7-O03 流程）；起反了 L2 卡住，必须 recover | ✅ |
| V7-X04 | L1 机 DNS 故障 | 改 `L1_RPC_URL_INTERNAL` / `L1_PROXY_UPSTREAM` 为不可达地址 + `l1-proxy restart` | l1-proxy `healthcheck` 仍 pass（只测 intercept 路径），但 op-batcher/op-node 全部 dial timeout | ⚠️ |
| V7-X05 | L1 机磁盘满 | L1 机 `dd if=/dev/zero of=/var/lib/docker/full bs=1M count=99999` | L1 geth 不再出块；L2 unsafe 继续；safe 不动；删 full 文件后 L1 恢复 | 🧪 |

### 9.4 Blockscout 机重启

| # | 用例 | 操作（Blockscout 机） | 预期 | 优先级 |
|---|---|---|---|---|
| V7-BS1 | Blockscout 重启 | `cd dev/blockscout-standalone && docker compose restart` | 链不受影响；浏览器 30s 内可达；不全表 re-index | ✅ |
| V7-BS2 | Blockscout 机 reboot | `sudo reboot` | 链完全无感；浏览器起来后从断点继续 index | ✅ |
| V7-BS3 | L2 机重启期间 Blockscout 在跑 | V7-B01 测试期间观察 Blockscout 日志 | backend 报 RPC 不可达 → 自动重试；链回来后追上 | ⚠️ |

---

## 10. 测试报告区（待回填）

> 跑完一轮后，把每个用例的结果填进这张大表。`pass=✅ / fail=❌ / skip=⏭ / partial=⚠️`

### 10.1 用例结果汇总

| 用例 | 操作时刻 | L1 停滞 (s) | L2 unsafe 停滞 (s) | L2 safe 恢复 (s) | I1-I10 不变量 | 结论 | 备注 |
|---|---|---:|---:|---:|---|---|---|
| V7-R01 l1-proxy restart           | | | | | | | |
| V7-R02 op-geth restart            | | | | | | | |
| V7-R03 op-rbuilder restart        | | | | | | | |
| V7-R04 rollup-boost restart       | | | | | | | |
| V7-R05 op-node restart            | | | | | | | |
| V7-R06 op-batcher restart         | | | | | | | |
| V7-R07 bundle-proxy restart       | | | | | | | |
| V7-R08 L1 geth restart            | | | | | | | |
| V7-R09 L1 down+up                 | | | | | | | |
| V7-R10 L1 restart 时 L2 观察      | | | | | | | |
| V7-C01 op-rbuilder rm+up          | | | | | | | |
| V7-C02 rollup-boost rm+up         | | | | | | | |
| V7-C03 op-geth rm+up              | | | | | | | |
| V7-C04 op-rbuilder 清卷+up        | | | | | | | |
| V7-G01 rbuilder+proxy 同挂        | | | | | | | |
| V7-G02 boost+opnode 同挂          | | | | | | | |
| V7-G03 geth+rbuilder 同挂         | | | | | | | |
| V7-G04 l1-proxy+batcher 同挂      | | | | | | | |
| V7-G05 全 v7 同挂                 | | | | | | | |
| V7-G06 L2 机全 stack 同挂         | | | | | | | |
| V7-F01 flashblocks-restart        | | | | | | | |
| V7-F02 flashblocks-clean+up       | | | | | | | |
| V7-O01 错序启动复现               | | | | | | | |
| V7-O02 recover 修复 O01           | | | | | | | |
| V7-O03 正常启动顺序               | | | | | | | |
| V7-O04 缺 jwt 启动                | | | | | | | |
| V7-D01 L2 机 systemctl restart    | | | | | | | |
| V7-B01 L2 机正常 reboot           | | | | | | | |
| V7-H01 L2 机 hard reset           | | | | | | | |
| V7-D02 dockerd OOM kill           | | | | | | | |
| **V7-LR1 L1 机 systemctl restart** | | | | | | | |
| **V7-LR2 L1 机正常 reboot**       | | | | | | | |
| **V7-LR3 L1 机 hard reset**       | | | | | | | |
| **V7-LR4 L1 长停 30min**          | | | | | | | |
| **V7-X01 L1↔L2 网络分区**         | | | | | | | |
| **V7-X02 X01 恢复**               | | | | | | | |
| **V7-X03 L1+L2 同时 hard reset**  | | | | | | | |
| V7-X04 L1 DNS 故障                | | | | | | | |
| V7-X05 L1 磁盘满                  | | | | | | | |
| V7-BS1 Blockscout restart         | | | | | | | |
| V7-BS2 Blockscout 机 reboot       | | | | | | | |
| V7-BS3 L2 重启时 Blockscout 观察  | | | | | | | |

### 10.2 总体判定

- [ ] 46 个用例全 pass / 不通过 X 个
- [ ] 8 个已知坑全部已堵
- [ ] 平均 L2 unsafe 停滞 < ___ s
- [ ] 最差 L2 safe 恢复 < ___ s（哪个用例：____）
- [ ] **L1 不变量 I1-I3 跨所有 LR/X 用例均 pass**（独立 L1 持久化的关键验证）
- [ ] 应急回退（§12）能在 5 min 内完成

### 10.3 行动项

| # | 问题 | 严重度 | 修复 owner | TODO |
|---|---|---|---|---|
|   |      |        |            |      |

---

## 11. 已知坑回归（必跑）

| # | 坑 | 来源 | 验证方法 | 现配置是否堵住 |
|---|---|---|---|---|
| K1 | ~~anvil 没设 `--mnemonic` 重启时 genesis hash 变 → L2 全失联~~ **已用独立 geth L1 替代 anvil，K1 彻底失效** | 2026-05-27 灾难 | 检查 `.env` 是 `COMPOSE_FILE=...:docker-compose.external-l1.yml` 且 `L1_RPC_URL_INTERNAL=http://l1-proxy:8546` | |
| K2 | op-node 启动时 rollup-boost 未 ready → 死等 | `dev-up-flashblocks-naive` 命名由来 | 跑 V7-O01 必然复现，跑 V7-O02 必能修 | |
| K3 | external-L1 模式 COMPOSE_FILE 漂移 | commit `0affea9` | `unset COMPOSE_FILE` 跑 `make flashblocks-up`，看是否自动带 external-l1.yml | |
| K4 | l1-proxy `eth_blobBaseFee` 拦截失效 | commit `4be6e5f`、`04034c2` | `docker exec l1-proxy python3 -c '...'` 调 `eth_blobBaseFee` 必须返 `0x1` | |
| K5 | op-geth `state.scheme=path` 不能切到 hash | `docker-compose.yml` 注释 | 改 `.env` 的 `OP_GETH_STATE_SCHEME=hash` 后 `up -d --force-recreate op-geth` 应该启动失败 | |
| K6 | flashblocks-rpc 老 image 协议不兼容 | `PHASE2_INTEGRATION.md` §0 | 启用 `--profile flashblocks-rpc` 后 bundle-proxy 应仍稳（read 默认 opgeth）| |
| K7 | rollup-boost / op-rbuilder distroless 无 shell healthcheck 永远 fail | `docker-compose.flashblocks.yml` 注释 | docker ps 看这俩没有 (healthy) 标签是正常的，不要误以为挂了 | |
| **K8** | **L1 hard reset 后 LevelDB 损坏** | 理论风险（README §6 已断言不会） | 跑 V7-LR3 后必须验 I3：L1 head 从原值 +1~2，不能从 0 起步 | |

---

## 12. 应急回退（v7 → v6 / 独立 L1 → anvil）

### 12.1 v7 → v6（L2 端回退）

如果 v7 整套挂得太严重一时修不好，应急回退到 v6（同一台机，同一份 op-geth 数据）：

```bash
# 1. 停 v7 三容器（保留 op-geth + op-node + op-batcher + 数据卷）
make flashblocks-down

# 2. op-node 的 engine 自动指回 op-geth 直连
docker compose --env-file .env up -d --force-recreate op-node op-batcher

# 3. 客户端把 RPC 从 :9560 (bundle-proxy) 改回 :9545 (op-geth)
```

回退后：
- ✅ dApp 通过 op-geth 直接发 tx，TPS 上限回到 ~180（v6 baseline）
- ✅ Blockscout 不受影响（本来就指 op-geth）
- ⚠️ 任何依赖 `eth_sendBundle` 的客户端要改回 `eth_sendRawTransaction`

### 12.2 独立 L1 → anvil（极端兜底，**不推荐**）

如果 L1 机彻底崩了一时修不好，临时切回 anvil：

```bash
# 警告：anvil 链跟独立 L1 的 chainId 可能一致但 genesis hash 不一样
# 切换 = 整条 L2 链失联（op-node derive 拒绝认这个 L1）
# 仅在 L1 数据彻底丢、要重建整条 L2 时才用

# 1. .env 改回 anvil 模式
sed -i 's|^COMPOSE_FILE=.*|# COMPOSE_FILE=|' .env
sed -i 's|^L1_RPC_URL_INTERNAL=.*|L1_RPC_URL_INTERNAL=http://anvil:8545|' .env

# 2. L2 必须 dev-clean（重建链）
make dev-clean
make dev-up-flashblocks

# ⚠️ 这会把所有 L2 业务数据全部丢失
```

**结论**：独立 L1 的所有 hard reset / reboot 用例（V7-LR1~LR4、V7-X01~X05）必须 100% pass，才能避免触发 §12.2。

---

## 13. 后续运维建议

### 13.1 监控告警必加（按 SLA 重要性排序）

| 优先级 | 指标 | 告警阈值 | 含义 |
|---|---|---|---|
| P0 | L1 `mychain-l1-geth` 进程存活 | 1 min 不存活告警 | 单点 |
| P0 | `rollup-boost` 进程存活 | 1 min 不存活告警 | v7 单点 |
| P0 | L2 `optimism_syncStatus.unsafe_l2.number` 5 min 增长 | < 1（理论应 ~300）告警 | 链停摆 |
| P1 | L2 `safe_l2` 5 min 增长 | < 1 告警 | L1 不通或 batcher 挂 |
| P1 | `bundle_proxy_inflight` | > 800（IN_FLIGHT_LIMIT 80%）告警 | 入流量超载预警 |
| P1 | `bundle_proxy_rpc_total{outcome="both_failed"}` 增长率 | > 0 告警 | rbuilder + fallback 双挂 |
| P2 | l1-proxy 容器健康 | 不 healthy 1 min 告警 | proxy 自身挂 |
| P2 | L1 ↔ L2 端到端延迟（safe head 滞后 unsafe head 多少块）| > 500 块（约 500s）告警 | L1 或 batcher 慢 |

### 13.2 重启策略

- 所有 v7 / L1 容器统一 `restart: unless-stopped`（已配）
- 但是 `dockerd restart` / `reboot` 会触发"启动顺序竞争"，可能命中 V7-O01：**整机重启后必须人工跑一次 `make flashblocks-smoke`，9/9 不通过就跑 `make flashblocks-recover`**
- L1 机和 L2 机如果**同时重启**，必须人工把 L1 先 `make up` 等 head 涨 ≥ 5 后再启 L2

### 13.3 不要在生产做的事

- 不要 `flashblocks-clean`（会清 rbuilder-data，重新 sync 数小时）
- 不要在 L1 机上 `cd dev/l1 && make clean`（**直接清掉整条 L1 链**）
- 不要 hard reset 没有云盘快照的机器
- 不要切 op-geth 的 state.scheme（K5）
- 不要把 anvil 切到独立 L1 或反向（chainId 即使一致 genesis hash 也不一致 → §12.2）

### 13.4 变更窗口建议

- 镜像升级 / 配置变更前先备份：
  - L2 机：`dev/workdir/` 整个目录
  - L1 机：`docker run --rm -v mychain-l1-geth-data:/data alpine tar czf - /data > l1-backup-$(date +%F).tgz`（停机后做更安全）
- bundle-proxy 镜像升级窗口 < 10s，可以工作时间做
- op-rbuilder / rollup-boost 升级会停链 ~30s，必须夜维护窗口
- **L1 节点升级必须停机 + 备份**，且要给 L2 一个静默期（L2 unsafe 仍出，但 safe 暂停）

---

## 14. 跟 V6 测试计划的关系

| 维度 | v6 | v7（本文档） |
|---|---|---|
| 容器数 | 4（anvil + geth + node + batcher）+ Blockscout | L1 机 1 + L2 机 7 + Blockscout 机 8 = **3 机 16 容器** |
| L1 | 内嵌 anvil（同机）| 独立 geth Clique（**另一台机**）|
| dApp 入口 | op-geth :9545 | bundle-proxy :9560 |
| 链停摆单点 | op-geth | rollup-boost（不是 L1，因为 L1 短停 L2 仍出 unsafe）|
| 启动顺序 | 简单 | 必须 op-geth→rollup-boost→op-node（v7 内部）+ L1→L2（跨机） |
| 重启自愈难度 | 低 | 中（多数自愈，但 dockerd restart 后可能需要 recover）|
| 跨机故障 | 无 | **必须测**（§9.3，5 个用例） |

→ v7 比 v6 多的测试重点：
1. **§6.2 L1 节点独立 restart**（v6 没有跨机概念）
2. **§9.2 L1 机整机重启**（验证 LevelDB 持久化）
3. **§9.3 跨机网络分区**（v6 不存在）
4. **§8 启动顺序 + recover**（v6 没有这个坑）

---
