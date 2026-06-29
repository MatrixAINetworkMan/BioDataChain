# RESTART_TEST_RUNBOOK_V7.md — v7 各模块重启测试：执行步骤 + 验收

> **用途**：这是 `RESTART_TEST_PLAN_V7.md` 的「动手执行」配套文档。计划文档讲“测什么/为什么”，
> 本文档讲「**怎么一步步跑、跑完怎么判断过没过**」。
> **核心验收只有两条硬指标**，每个模块都要分别打勾：
>   1. **能否恢复** —— restart / 重启后，模块能不能自己回到正常出块 / 服务。
>   2. **会不会丢数据** —— 已落盘的链上数据是否 0 丢失（**只有有持久卷的模块才需要测这条**）。
> **配套**：`RESTART_TEST_PLAN_V7.md`（用例全集 / 不变量 I1-I10 / 已知坑 K1-K8）、`dev/l1/README.md`、`dev/blockscout-standalone/运维交接文档.md`

---

## 0. 测试前必填：连接与变量

> ⚠️ 本文档所有命令都用 SSH 别名 `l1 / chain / scan`。**开跑前先把下面三台机填好**
> （写进 `~/.ssh/config`，或把命令里的别名替换成 `user@host`）。

```bash
# ===== 在控制机（你的本地）执行，一次性填写 =====
# 三台机 SSH（别名或 user@host 都行）
export L1_SSH=l1          # 独立 geth Clique（dev/l1）
export CHAIN_SSH=chain    # op-geth/op-node/op-batcher/op-proposer/Flashblocks 三件套/l1-proxy/bundle-proxy
export SCAN_SSH=scan      # blockscout-standalone（8 容器）

# 对外域名（验收 invariant 用）
export L1_RPC=https://devl1.example.com/rpc   # L1 RPC（公网）
export L2_RPC=https://<l2-domain>/rpc          # L2 RPC（公网，走 bundle-proxy）
export SCAN_URL=https://<scan-domain>          # 浏览器

# 各机部署目录（按实际改）
export L1_DIR=~/mychain/dev/l1
export CHAIN_DIR=~/mychain/dev
export SCAN_DIR=~/mychain/dev/blockscout-standalone
```

自检三台机连通（开跑前必过）：

```bash
ssh $L1_SSH    "cd $L1_DIR && docker compose ps | tail -n +1"
ssh $CHAIN_SSH "cd $CHAIN_DIR && docker compose ps | tail -n +1"
ssh $SCAN_SSH  "cd $SCAN_DIR && docker compose ps | tail -n +1"
```

---

## 1. 两条验收硬指标的判定标准

每个用例跑完，对照下表给出 **可恢复 ✅/❌** 和 **数据无损 ✅/❌（或 N/A）** 两个结论。

### 1.1 「能否恢复」判定（所有模块都测）

| 判据 | 通过标准 | 命令 / 不变量 |
|---|---|---|
| 容器回到 running/healthy | 目标容器 `State=running`，有 health 的为 `healthy`（注意 K7：rollup-boost/op-rbuilder 无 shell，永远没 healthy 标签，属正常） | `docker inspect -f '{{.State.Status}}'` |
| L2 unsafe head 恢复涨 | 重启窗口允许暂停，恢复后单调增、无 reorg（I6） | `eth_blockNumber` via bundle-proxy |
| L2 safe head 恢复涨 | ≤ 180s 内 `optimism_syncStatus.safe_l2.number` 开始涨（I7） | op-node `optimism_syncStatus` |
| L1 head 恢复涨 | 暂停 < 4s，恢复接上原值，**绝不从 0 起步**（I3） | `eth_blockNumber` via L1 RPC |
| 入口可用 | bundle-proxy `/status` 的 `circuit=closed`（I10） | `curl :9560/status` |
| 冒烟 | `make flashblocks-smoke` 9/9（或 8/8） | 链机执行 |

### 1.2 「会不会丢数据」判定（仅有状态卷的 4 个模块）

| 有状态模块 | 卷 | 数据无损通过标准 | 命令 / 不变量 |
|---|---|---|---|
| **L1 geth** | `mychain-l1-geth-data` | genesis hash 不变（I2）+ head 不归零（I3）+ 重启前记录的 L1 tx 仍可查（I8） | `cast block 0`、`cast tx <hash>` |
| **op-geth** | `opgeth-data` | genesis hash 不变（I5）+ 历史 L2 tx 可查（I8）+ deployer 余额一致 + **日志无 re-init genesis** | `cast block 0`、`cast tx`、`cast balance` |
| **op-rbuilder** | `rbuilder-data` | restart 后 block-number 接上原 head（**不从 0 re-sync**） | `cast block-number` 直连 :9550 |
| **Blockscout** | `bs-db` / `bs-stats-db` | 索引为非权威数据：块号能从断点追平即可（丢了可从链 re-index 重建） | 首页块号 / `/api/v2/blocks` |
| 其余无状态模块 | — | **N/A**（l1-proxy / rollup-boost / op-node / op-batcher / op-proposer / bundle-proxy 无持久链数据） | — |

### 1.3 FAIL 红线（任一出现即不通过）

- ❌ L1 / L2 head 倒退或从 0 起步
- ❌ `optimism_syncStatus` 卡某高度 > 5 min
- ❌ op-node 日志 `genesis hash mismatch` / `L1 chain has reset` / `unsafe head rewind`
- ❌ op-rbuilder 日志 `state root mismatch` / `parent hash unknown`
- ❌ bundle-proxy `both_failed` 计数增长
- ❌ rollup-boost 重启后 op-node 卡 `Waiting for L2 engine` > 60s（须 `flashblocks-recover`）

---

## 2. 通用执行流程（每个用例都走这 6 步）

```
① 快照前   → bash /tmp/snap.sh > /tmp/before.txt        # 见 §3 脚本
② 记位置点 → source /tmp/pre.env                         # 见 §3 脚本，记 head / benchmark tx / 余额
③ 开 watcher（3 个 tmux：L1 head / L2 unsafe / L2 safe，见 RESTART_TEST_PLAN_V7.md §4.2）
④ 执行操作 → 见 §4 各模块命令；同时秒表计时（停滞 / 恢复秒数）
⑤ 验收     → bash /tmp/snap.sh > /tmp/after.txt; diff -u /tmp/before.txt /tmp/after.txt
            → 按 §1.1 勾「可恢复」、§1.2 勾「数据无损」
            → make flashblocks-smoke
⑥ 记结果   → 填 §5 表 + 写 docs/RESTART_TEST_RUN_<date>.md 一行（PASS/FAIL/blocker）
```

---

## 3. 工具脚本（开跑前一次性放到对应机器）

### 3.1 快照脚本 `/tmp/snap.sh`（放链机 `$CHAIN_SSH`）

> 完整版见 `RESTART_TEST_PLAN_V7.md` §4.1。最小可用版：

```bash
ssh $CHAIN_SSH 'cat > /tmp/snap.sh' <<"EOF"
#!/usr/bin/env bash
set -u
H=127.0.0.1
rpc(){ curl -s --max-time 3 -X POST "$1" -H 'content-type: application/json' -d "$2"; }
bn(){ rpc "$1" '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq -r '.result//"ERR"'; }
echo "=== $(date -Iseconds) ==="
printf "L2 unsafe (bundle-proxy:9560) %s\n" "$(bn http://$H:9560)"
printf "L2 unsafe (op-geth:9545)      %s\n" "$(bn http://$H:9545)"
printf "L2 unsafe (op-rbuilder:9550)  %s\n" "$(bn http://$H:9550)"
rpc http://$H:9547 '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
  | jq -r '.result|"safe=\(.safe_l2.number) finalized=\(.finalized_l2.number) head_l1=\(.head_l1.number)"' 2>/dev/null || echo "op-node ❌"
curl -s --max-time 3 http://$H:9560/status | jq -c '{circuit,inflight,head:.head.number}' 2>/dev/null || echo "proxy ❌"
for c in mychain-op-geth mychain-op-rbuilder mychain-rollup-boost mychain-op-node mychain-op-batcher mychain-op-proposer mychain-bundle-proxy l1-proxy; do
  printf "  %-24s %s\n" "$c" "$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}—{{end}}' "$c" 2>/dev/null||echo missing)"
done
EOF
ssh $CHAIN_SSH 'chmod +x /tmp/snap.sh'
```

### 3.2 位置点 `/tmp/pre.env`（重启前记录基准）

```bash
# 在控制机执行，把基准存到本地，方便重启后比对
ssh $CHAIN_SSH "bash /tmp/snap.sh" > /tmp/before.txt
L1_HEAD=$(cast block-number --rpc-url $L1_RPC)
L2_HEAD=$(cast block-number --rpc-url $L2_RPC)
L1_BENCH_TX=$(cast block latest --rpc-url $L1_RPC --json | jq -r '.transactions[0] // empty')
L2_BENCH_TX=$(cast block latest --rpc-url $L2_RPC --json | jq -r '.transactions[0] // empty')
echo "L1_HEAD=$L1_HEAD L2_HEAD=$L2_HEAD L1_BENCH_TX=$L1_BENCH_TX L2_BENCH_TX=$L2_BENCH_TX" | tee /tmp/pre.env
```

### 3.3 背景流量（可选，验证 mempool 行为）

```bash
ssh $CHAIN_SSH "cd $CHAIN_DIR && make bot-token-spam-up TARGET_TPS=50"
```

---

## 4. 逐模块执行步骤（每节 = 命令 + 恢复验收 + 数据无损验收）

> 约定：🟢 自愈（无需人工） · 🟡 需关注启动顺序 · 🔴 单点 / 高危。
> 每个模块给「最小破坏（restart）」步骤；机器级（reboot / hard reset）见 §4.11。

---

### 4.1 🟢 l1-proxy（链机，无状态）—— V7-R01

```bash
# 执行
ssh $CHAIN_SSH "cd $CHAIN_DIR && docker compose --env-file .env restart l1-proxy"
```

- **能否恢复**：~3s 内 `l1-proxy` 回 running；op-batcher 日志最多 1-2 次 `will retry`，无残留。
  ```bash
  ssh $CHAIN_SSH "docker inspect -f '{{.State.Status}}' l1-proxy"
  ssh $CHAIN_SSH "docker logs mychain-op-batcher --tail=20 | grep -i retry"   # ≤3 次
  ssh $CHAIN_SSH 'docker exec l1-proxy python3 -c "import urllib.request as u,json;print(json.loads(u.urlopen(u.Request(\"http://127.0.0.1:8546\",data=b\"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"method\\\":\\\"eth_blobBaseFee\\\",\\\"params\\\":[],\\\"id\\\":1}\",headers={\"Content-Type\":\"application/json\"})).read())[\"result\"])"'   # 必须 0x1 (K4)
  ```
- **数据无损**：N/A（无状态）。

---

### 4.2 🟢 op-geth（链机，有状态卷 `opgeth-data`）—— V7-R02 / V7-C03

```bash
# restart
ssh $CHAIN_SSH "cd $CHAIN_DIR && docker compose restart op-geth"
# rm+up（保留卷，关键回归 V7-C03）
ssh $CHAIN_SSH "cd $CHAIN_DIR && docker compose rm -fs op-geth && docker compose --env-file .env up -d op-geth"
```

- **能否恢复**：op-geth 起来后追上 head；期间 rollup-boost 仍可单路 dispatch 给 op-rbuilder（链不停）。
- **数据无损**：
  ```bash
  cast block 0 --rpc-url $L2_RPC --json | jq -r .hash      # genesis hash 不变 (I5)
  cast tx $L2_BENCH_TX --rpc-url $L2_RPC | head -3         # 历史 tx 仍可查 (I8)
  ssh $CHAIN_SSH "docker logs mychain-op-geth --tail=50 | grep -iE 'init genesis|Initializing'"   # 必须为空，禁止 re-init
  ```

---

### 4.3 🟢 op-rbuilder（链机，有状态卷 `rbuilder-data`）—— V7-R03 / V7-C01

```bash
ssh $CHAIN_SSH "cd $CHAIN_DIR && docker compose restart op-rbuilder"
```

- **能否恢复**：bundle-proxy 触发熔断 → fallback 到 op-geth；rbuilder 起来后 ~10s 熔断器 reset。
  ```bash
  curl -s $L2_RPC/../status 2>/dev/null; ssh $CHAIN_SSH "curl -s http://127.0.0.1:9560/status | jq .circuit"  # 最终 closed (I10)
  ssh $CHAIN_SSH "curl -s http://127.0.0.1:9560/metrics | grep rbuilder_fail_fallback_ok"   # 应 >0
  ```
- **数据无损**：restart 后从 `rbuilder-data` 卷接上 head（**不从 0 re-sync**）。
  ```bash
  ssh $CHAIN_SSH "cast block-number --rpc-url http://127.0.0.1:9550"   # 接近重启前 L2_HEAD，非 0
  ```
- ⚠️ **不要清 `rbuilder-data` 卷**（V7-C04）：清卷=从 genesis re-sync 数小时，**演练才做，需你显式同意**。

---

### 4.4 🔴 rollup-boost（链机，无状态，**v7 唯一停链单点**）—— V7-R04 / V7-C02

```bash
ssh $CHAIN_SSH "cd $CHAIN_DIR && docker compose restart rollup-boost"
```

- **能否恢复**：链出块停 ~15s（op-node 重连 engine API），之后恢复；safe head 滞后 ~30s 恢复。
  ```bash
  ssh $CHAIN_SSH "docker logs mychain-op-node --tail=50 | grep -i 'Waiting for L2 engine'"   # 不能 >60s
  # 若卡住 → 一键修复（见 §6）
  ```
- **数据无损**：N/A（无状态）。

---

### 4.5 🟡 op-node（链机，基本无状态）—— V7-R05

```bash
ssh $CHAIN_SSH "cd $CHAIN_DIR && docker compose restart op-node"
```

- **能否恢复**：engine FCU 暂停 ~10s，op-node 起来后从 rollup-boost 重新拿 head 继续 sequence。
  - ⚠️ **启动顺序坑（K2）**：op-node 启动时 rollup-boost 必须已 healthy，否则死等 `Waiting for L2 engine`。
- **数据无损**：N/A。

---

### 4.6 🟢 op-batcher（链机，无状态）—— V7-R06

```bash
ssh $CHAIN_SSH "cd $CHAIN_DIR && docker compose restart op-batcher"
```

- **能否恢复**：unsafe head 不受影响；safe head 暂停后自动追上。
  ```bash
  watch -n2 'ssh '"$CHAIN_SSH"' "curl -s -X POST http://127.0.0.1:9547 -H content-type:application/json -d {\"jsonrpc\":\"2.0\",\"method\":\"optimism_syncStatus\",\"params\":[],\"id\":1}" | jq .result.safe_l2.number'
  ```
- **数据无损**：N/A。

---

### 4.7 🟢 op-proposer（链机，无状态，**关系 withdrawal/output root**）—— V7-R06b 〔计划新增〕

```bash
ssh $CHAIN_SSH "cd $CHAIN_DIR && docker compose restart op-proposer"
```

- **能否恢复**：output root 提交暂停后自动补提；L1 上 L2OutputOracle/`DisputeGame` 的 output 继续推进。
  ```bash
  ssh $CHAIN_SSH "docker logs mychain-op-proposer --tail=30 | grep -iE 'output|proposal'"   # 恢复后有新提交
  ```
- **数据无损**：N/A（无状态），但**这是提现链路的关键**——恢复失败 = withdrawal 卡住。

> 注：本用例计划文档 §6 原缺，按本轮 review 补入。

---

### 4.8 🟢 bundle-proxy（链机，无状态，dApp 入口）—— V7-R07

```bash
ssh $CHAIN_SSH "cd $CHAIN_DIR && make flashblocks-restart-proxy"
```

- **能否恢复**：dApp 收 5xx ~5s；链不受影响；`/status` circuit=closed。
  ```bash
  ssh $CHAIN_SSH "curl -s http://127.0.0.1:9560/status | jq '{circuit,head:.head.number}'"
  ```
- **数据无损**：N/A。

---

### 4.9 🟢 L1 geth（L1 机，有状态卷 `mychain-l1-geth-data`）—— V7-R08 / V7-R09 / V7-R10

```bash
# restart（最快）
ssh $L1_SSH "cd $L1_DIR && docker compose --env-file .env restart geth-l1"
# down+up（容器重建，验证卷持久化 V7-R09）
ssh $L1_SSH "cd $L1_DIR && make down && make up"
```

- **能否恢复**：L1 出块暂停 ~5s，恢复后接上原 head（不归零）。同时在链机看 V7-R10：L2 unsafe **不受影响**，safe 暂停 ~10s 恢复。
  ```bash
  ssh $L1_SSH "cd $L1_DIR && make status"        # Block# 接上原值
  cast block-number --rpc-url $L1_RPC            # 非 0、≥ 重启前 L1_HEAD
  ```
- **数据无损**（重点！）：
  ```bash
  cast block 0 --rpc-url $L1_RPC --json | jq -r .hash    # genesis hash 不变 (I2)
  cast tx $L1_BENCH_TX --rpc-url $L1_RPC | head -3        # 历史 L1 tx 可查 (I8)
  # I3：head 必须 ≥ 重启前值，绝不从 0
  ```

---

### 4.10 🟢 Blockscout（浏览器机，有状态卷 `bs-db`/`bs-stats-db`）—— V7-BS1

```bash
ssh $SCAN_SSH "cd $SCAN_DIR && docker compose restart"
```

- **能否恢复**：链不受影响；浏览器 30s 内可达；不全表 re-index。
  ```bash
  curl -s "$SCAN_URL/api/v2/blocks?limit=1" | head -c 200    # 返回含 "items" 的 JSON
  ```
- **数据无损**：索引为非权威数据 —— 块号能从断点继续追平即算过（极端情况可 re-index 重建，不算丢链数据）。

---

### 4.11 🔴 机器级：reboot / hard reset（**需 §0 安全档位授权 + 云盘快照**）

> ⚠️ 以下属破坏性操作。**未经你显式同意不执行**。hard reset 前必须确认有云盘快照。

| 用例 | 机器 | 命令 | 恢复验收 | 数据无损验收 |
|---|---|---|---|---|
| V7-D01 | 链机 | `sudo systemctl restart docker` | 容器 auto-start；若卡 K2 顺序 → `flashblocks-recover` | op-geth/rbuilder 卷接上 head |
| V7-B01 | 链机 | `sudo reboot` | 同上 + 开机全容器 auto-start | 同上 |
| V7-H01 | 链机 | `sudo sync; echo b >/proc/sysrq-trigger` | 同上 | op-geth LevelDB WAL 不丢已上链 block |
| V7-LR1 | L1 机 | `sudo systemctl restart docker` | L2 unsafe 续；safe ~30s 恢复 | L1 head 不归零 |
| V7-LR2 | L1 机 | `sudo reboot` | safe 60-120s 追上 | I2/I3 |
| **V7-LR3** | L1 机 | `sudo sync; echo b >/proc/sysrq-trigger` | **最关键**：geth LevelDB+WAL 不丢块 | **I3：head +1~2，绝不从 0（K8）** |
| V7-BS2 | 浏览器机 | `sudo reboot` | 链无感；浏览器从断点续 index | 索引可追平 |

---

### 4.12 🔴 跨机 / 组合故障（L7）—— V7-G / V7-X 系列

| 用例 | 操作 | 恢复要点 |
|---|---|---|
| V7-G02 | rollup-boost + op-node 同停 | 起来顺序必须 boost → op-node（用 `flashblocks-recover`） |
| V7-G06 | 链机全 stack 同停（`make dev-down`） | 起来后 head 必须接上；L1 机不受影响 |
| V7-X01/02 | L1↔L2 网络分区（`iptables -A/-D OUTPUT -d <L1_IP> -j DROP`） | 恢复后 30s 内 derive/batcher 自动追上 |
| V7-X03 | L1+L2 同时 hard reset | **必须先起 L1，等 head≥5，再起 L2**（C10） |

---

## 5. 结果记录表（每跑一个用例填一行）

> `可恢复` / `数据无损` 两列是本轮核心验收；`数据无损` 对无状态模块填 `N/A`。
> 跑完每个用例同时往 `docs/RESTART_TEST_RUN_<date>.md` 追加一行（PASS/FAIL/blocker）。

| 用例 | 模块 | 操作时刻 | 停滞(s) | safe恢复(s) | **可恢复** | **数据无损** | 结论 | 备注 |
|---|---|---|---:|---:|:---:|:---:|---|---|
| V7-R01 | l1-proxy | | | | | N/A | | |
| V7-R02 | op-geth | | | | | | | |
| V7-R03 | op-rbuilder | | | | | | | |
| V7-R04 | rollup-boost | | | | | N/A | | |
| V7-R05 | op-node | | | | | N/A | | |
| V7-R06 | op-batcher | | | | | N/A | | |
| V7-R06b | op-proposer | | | | | N/A | | |
| V7-R07 | bundle-proxy | | | | | N/A | | |
| V7-R08 | L1 geth restart | | | | | | | |
| V7-R09 | L1 down+up | | | | | | | |
| V7-R10 | L1 重启时 L2 观察 | | | | | N/A | | |
| V7-C01 | op-rbuilder rm+up | | | | | | | |
| V7-C03 | op-geth rm+up | | | | | | | |
| V7-BS1 | Blockscout restart | | | | | | | |
| V7-D01 | 链机 systemctl docker | | | | | | | |
| V7-B01 | 链机 reboot | | | | | | | |
| V7-H01 | 链机 hard reset | | | | | | | |
| V7-LR1 | L1 机 systemctl docker | | | | | | | |
| V7-LR2 | L1 机 reboot | | | | | | | |
| V7-LR3 | L1 机 hard reset | | | | | | | |
| V7-BS2 | 浏览器机 reboot | | | | | | | |
| V7-G02 | boost+opnode 同挂 | | | | | N/A | | |
| V7-G06 | 链机全 stack 同挂 | | | | | | | |
| V7-X01 | L1↔L2 网络分区 | | | | | N/A | | |
| V7-X03 | L1+L2 同时 hard reset | | | | | | | |

### 5.1 总体判定

- [ ] 所有勾选用例 **可恢复 = ✅**
- [ ] 4 个有状态模块（L1-geth / op-geth / op-rbuilder / Blockscout）**数据无损 = ✅**
- [ ] **V7-LR3（L1 hard reset）I3 通过**：head 不从 0 起步（K8 最强验证）
- [ ] 最差 safe 恢复 < ___ s（用例：___）

---

## 6. 出问题怎么办（恢复手册）

| 症状 | 处理 |
|---|---|
| op-node 卡 `Waiting for L2 engine` | `ssh $CHAIN_SSH "cd $CHAIN_DIR && make flashblocks-recover"`（rm op-node/op-batcher → 确认 op-geth healthy → 起 boost → 起 op-node） |
| 整机重启后顺序竞争（K2） | 先 `make flashblocks-smoke`，9/9 不过就 `make flashblocks-recover` |
| L1 head 从 0 起步 | **立即停止所有操作**：LevelDB 损坏或挂错卷，排查 `mychain-l1-geth-data` 是否被误清 |
| L1+L2 同时挂 | **先起 L1**（`make up`，等 head≥5）→ 再起 L2（`make dev-up-flashblocks`） |
| v7 整套挂太重一时修不好 | 应急回退 v6：`make flashblocks-down` → `up -d --force-recreate op-node op-batcher` → 客户端 RPC 改回 :9545（见 PLAN §12） |

### 6.1 禁止动作（除非你显式同意）

- ❌ `docker compose down -v`（清卷）
- ❌ `make flashblocks-clean`（清 rbuilder-data，re-sync 数小时）
- ❌ L1 机 `make clean`（直接清掉整条 L1 链）
- ❌ hard reset 没有云盘快照的机器
- ❌ 切 op-geth `state.scheme`（K5）

---

## 7. 与计划文档的关系

| 文档 | 角色 |
|---|---|
| `RESTART_TEST_PLAN_V7.md` | 全集 / 为什么测 / 依赖矩阵 / 不变量定义（46 用例） |
| **本文档** | **怎么一步步跑 + 两条硬指标怎么验收**（执行手册） |
| `docs/RESTART_TEST_RUN_<date>.md` | 每次实跑的逐行结果记录（PASS/FAIL/blocker） |
