# MACHINE_MIGRATION_RUNBOOK_V7.md — L2 机切换（迁移 / 换机）测试流程

> **用途**：验证「关掉老 L2 机、在新机上恢复 L2」是否能做到**无损**。
> 核心前提：**L1 机独立、不动**；L2 是从 L1 确定性派生（OP Stack），只要带齐配置就能恢复。
> **配套**：`RESTART_TEST_PLAN_V7.md`（不变量 I1-I10 / 已知坑 K1-K8）、`RESTART_TEST_RUNBOOK_V7.md`、`dev/l1/README.md`
> **适用拓扑**：external-l1 模式（`COMPOSE_FILE=docker-compose.yml:docker-compose.external-l1.yml`），
>   当前 L2 为 **op-geth 单 sequencer**（op-geth + op-node + op-batcher + l1-proxy）。
>   若已启用 Flashblocks 三件套（op-rbuilder / rollup-boost / bundle-proxy），见 §9 附加项。

---

## 0. 一页速览

```
┌──────────────┐     RPC :8545      ┌─────────────────── 老 L2 机（待退役）────────────────┐
│ L1 机         │ ◀───────────────── │  l1-proxy → op-node/op-batcher                        │
│ （独立不动）  │                    │  op-geth (sequencer, 卷 dev_opgeth-data) ← 唯一有状态 │
│ archive 全历史│                    └──────────────────────────────────────────────────────┘
└──────────────┘                                       │ 迁移
        ▲                            ┌─────────────────── 新 L2 机 ──────────────────────────┐
        └─────────────────────────── │  同一份 workdir/shared + .env + （可选）opgeth-data 卷 │
                  RPC :8545           │  起 op-geth/op-node/op-batcher/l1-proxy → 接回同一 L1  │
                                      └──────────────────────────────────────────────────────┘
```

**两条迁移路径，先选一条：**

| 方式 | 做法 | 无损程度 | 耗时 | 推荐场景 |
|---|---|---|---|---|
| **A：搬数据卷** | 拷 `dev_opgeth-data` 卷 + `workdir/` + `.env` | **真·无损**（连最新 unsafe 块都不丢） | 分钟级（看卷大小） | 计划内换机、卷不大 |
| **B：纯从 L1 重建** | 只带 `workdir/shared` + `.env`，op-geth 从 genesis 让 op-node 从 L1 重放 | **无损到 safe head**（丢最尾部还没上 L1 的几个块） | 十几分钟~数小时（看链龄） | 老机磁盘损坏、卷拷不出来 |

**最关键的一条铁律（K1 灾难本质）**：新机**绝不能重新 `deploy`**。必须复用老机的 `workdir/shared/`，否则 genesis hash / 合约地址变化 → op-node 报 `L1 chain has reset` 拒绝 derive = 开了条新链，不是恢复。

---

## 1. 为什么能恢复（原理 + 无损边界）

- L2 的 safe / finalized 状态锚定在 L1 上；op-batcher 持续把压缩后的 L2 区块投到 L1。
- `op-node` 可反向从 L1 读取这些 batch + deposit，**确定性重放**出整条 L2，再通过 engine API 喂给 op-geth 重新执行、重建 state。
- `op-node` / `op-batcher` / `l1-proxy` **本身无持久链数据**（op-node 只挂 `workdir/shared:ro`），所以它们在新机上是“从零起、自动对齐”，不需要搬。
- L2 机唯一的有状态卷是 **`dev_opgeth-data`**（docker compose 项目名 = 目录名 `dev`）。

**无损边界：**

```
已投到 L1 的部分（safe head 及以下）   →  100% 可恢复，无损
还没投 L1 的 unsafe 尾部（最近几个块）  →  方式 B 会丢；方式 A 搬卷不丢
```

被丢掉的 unsafe 尾部块本来 confirmations=0、无安全保证，丢失符合预期。

---

## 2. 前置条件（开跑前必须全部满足）

| # | 条件 | 检查命令 |
|---|---|---|
| P1 | L1 机健康、head 在涨、与新机网络可达 | `cast block-number --rpc-url $L1_RPC_EXTERNAL` |
| P2 | 老机能列出 `dev_opgeth-data` 卷 | `docker volume ls \| grep opgeth-data` |
| P3 | 老机 `dev/workdir/shared/` 内有 genesis.json / rollup.json / jwt.txt 等 | `ls dev/workdir/shared/` |
| P4 | 新机已装 docker + docker compose v2.20+（external-l1 用了 `!override`） | `docker compose version` |
| P5 | 新机能拉到同版本镜像（op-geth v1.101702.1 等，见 `.env`） | `docker pull <image>` |
| P6 | 记录老机基准（迁移后比对） | 见 §3 |

---

## 3. 迁移前记录基准（无损判定的对照基线）

在**老机**执行，存到控制机：

```bash
# 老机 L2 RPC（按实际端口，默认 9545）
L2=http://127.0.0.1:9545
# 基准三件套
echo "genesis_hash=$(cast block 0 --rpc-url $L2 --json | jq -r .hash)"     # I5 比对锚点
echo "head=$(cast block-number --rpc-url $L2)"                             # I6 比对锚点
echo "bench_tx=$(cast block latest --rpc-url $L2 --json | jq -r '.transactions[0] // empty')"  # I8 比对
# op-node safe / finalized
curl -s -X POST http://127.0.0.1:9547 -H content-type:application/json \
  -d '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
  | jq '.result | {unsafe:.unsafe_l2.number, safe:.safe_l2.number, finalized:.finalized_l2.number}'
# chainId
echo "chainId=$(cast chain-id --rpc-url $L2)"                              # I4 比对
```

把输出存成 `/tmp/migrate-before.txt`。**genesis_hash 和 chainId 是迁移后必须 100% 一致的硬指标。**

---

## 4. 方式 A：搬数据卷（真·无损，推荐）

### 4.1 老机：优雅停 + 打包

```bash
cd dev
# 先停 batcher 让最后一批尽量上 L1，再停 node、最后停 geth（减少 unsafe 丢失）
docker compose stop op-batcher && sleep 5
docker compose stop op-node op-geth l1-proxy

# 打包数据卷（卷名 dev_opgeth-data）
docker run --rm -v dev_opgeth-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/opgeth-data.tgz -C /data .

# 打包配置（workdir + 两个 env + l1-proxy 脚本）
tar czf migrate-config.tgz workdir .env .env.flashblocks l1-proxy/proxy.py
```

> ⚠️ 必须先停 op-geth 再打包，避免拷到“正在写入”的不一致 LevelDB（path scheme）。

### 4.2 拷到新机

```bash
scp dev/opgeth-data.tgz   dev/migrate-config.tgz   newhost:/data/code/mychain/dev/
# 同时把整个 repo 也拉到新机（git clone 或 rsync 代码）
```

### 4.3 新机：恢复卷 + 配置 + 起服务

```bash
cd /data/code/mychain/dev

# 1) 恢复配置
tar xzf migrate-config.tgz

# 2) 创建并恢复数据卷（注意卷名要跟项目名一致 = dev_opgeth-data）
docker volume create dev_opgeth-data
docker run --rm -v dev_opgeth-data:/data -v "$PWD":/backup alpine \
  sh -c "tar xzf /backup/opgeth-data.tgz -C /data"

# 3) 确认 .env 里 external-l1 三行没改（L1 机没变，指向同一 L1）
grep -E 'COMPOSE_FILE|L1_RPC_URL_INTERNAL|L1_PROXY_UPSTREAM|L1_RPC_URL_EXTERNAL' .env

# 4) 起服务 —— 关键：跳过 deploy/init，直接 up 运行态容器
docker compose --env-file .env up -d l1-proxy op-geth op-node op-batcher
```

> ⚠️ **绝对不要**在新机跑 `make deploy-l1 / deploy-genesis / init-geth / dev-up`——那会重 init genesis 覆盖卷。直接 `up -d` 让 op-geth 复用已恢复的 chaindata。

### 4.4 跳到 §6 验收

---

## 5. 方式 B：纯从 L1 重建（无损到 safe head）

老机数据卷拷不出来（磁盘坏 / 太大）时用这条。新机只需要 `workdir/shared` + `.env`。

### 5.1 新机：带配置，但 op-geth 用 fresh datadir 重新 init

```bash
cd /data/code/mychain/dev
tar xzf migrate-config.tgz          # 只用里面的 workdir/.env，不含 opgeth-data

# 用老机的 genesis.json 重新 init op-geth datadir（fresh 卷）
docker compose --env-file .env --profile deploy up op-geth-init
# ↑ 它只做 geth init（从 workdir/shared/genesis.json），不会重新部署合约

# 起服务，op-node 会从 L1 重放把 op-geth 推到 safe head
docker compose --env-file .env up -d l1-proxy op-geth op-node op-batcher
```

### 5.2 观察重放进度

```bash
# unsafe head 应从 0 快速往上爬（重放比实时快很多）
watch -n 2 'curl -s -X POST http://127.0.0.1:9547 -H content-type:application/json \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"optimism_syncStatus\",\"params\":[],\"id\":1}" \
  | jq ".result | {unsafe:.unsafe_l2.number, safe:.safe_l2.number}"'
```

预期：unsafe / safe head 持续上涨，最终追平老机基准 head 附近（差最尾部几个未上 L1 的块）。耗时见 §0 表（十几分钟~数小时，取决于链龄与负载）。

### 5.3 跳到 §6 验收

---

## 6. 验收标准（迁移成功 = 下面全过）

在**新机**跑 §3 同样的命令，存 `/tmp/migrate-after.txt`，逐条比对：

| # | 验收项 | 通过标准 | 不变量 |
|---|---|---|---|
| V1 | **genesis hash 一致** | `cast block 0` 的 hash == 老机基准 | I5 |
| V2 | **chainId 一致** | `cast chain-id` == 老机基准 | I4 |
| V3 | **head 不归零、追上** | 方式 A：≥ 老机 head；方式 B：追到老机 head 附近 | I6 |
| V4 | **safe head 在涨** | `optimism_syncStatus.safe_l2.number` 持续增长 | I7 |
| V5 | **历史 tx 可查** | `cast tx <bench_tx>` 返回 receipt | I8 |
| V6 | **op-node 日志干净** | 无 `genesis hash mismatch` / `L1 chain has reset` / `unsafe head rewind` | §2.2 |
| V7 | **op-batcher 正常 post** | 日志无持续 `eth_blobBaseFee` 报错（l1-proxy 生效）；safe 能涨 | K4 |
| V8 | **容器健康** | op-geth/op-node healthy，op-batcher/l1-proxy running | — |

```bash
# 一键比对
diff -u /tmp/migrate-before.txt /tmp/migrate-after.txt
# op-node 日志红线检查
docker logs mychain-op-node --tail=200 | grep -iE 'mismatch|chain has reset|rewind' && echo "❌ 出现红线" || echo "✅ 无红线"
# l1-proxy 拦截校验（K4）
docker exec l1-proxy python3 -c 'import urllib.request as u,json;print(json.loads(u.urlopen(u.Request("http://127.0.0.1:8546",data=b"{\"jsonrpc\":\"2.0\",\"method\":\"eth_blobBaseFee\",\"params\":[],\"id\":1}",headers={"Content-Type":"application/json"})).read())["result"])'   # 必须 0x1
```

---

## 7. FAIL 红线（出现任一立即停止排查）

- ❌ 新机 genesis hash / chainId 跟老机**不一致** → 几乎一定是新机误跑了 deploy/init，覆盖了配置。停，重来。
- ❌ op-node 日志 `L1 chain has reset` / `genesis hash mismatch` → workdir/shared 没带对，或指向了不同 L1。
- ❌ op-geth head 从 0 起步且不增长 → 卷没恢复成功 / 卷名不对（必须 `dev_opgeth-data`）。
- ❌ safe head 长时间不动（> 5 min）→ op-batcher 连不上 L1（检查 `L1_PROXY_UPSTREAM` 是否指对 L1 机）。

---

## 8. 回滚预案（迁移失败时）

迁移本身**不破坏老机**（老机只是 stop，卷还在）。失败就回滚：

```bash
# 新机：停掉半成品
docker compose --env-file .env down            # 注意：不要加 -v，别清卷
# 老机：重新拉起（数据卷一直都在）
cd dev && docker compose --env-file .env up -d l1-proxy op-geth op-node op-batcher
```

> 老机在确认新机验收全过、稳定运行 ≥ 1 小时前，**不要 `down -v` 或销毁**。

---

## 9. 附加项：若已启用 Flashblocks 三件套

当前部署是 op-geth 单 sequencer，**不涉及**下列内容。将来若启用了 v7 Flashblocks：

- 额外有状态卷：**`dev_rbuilder-data`**（op-rbuilder 的 datadir）——方式 A 要一并打包搬运。
- 额外无状态容器：`rollup-boost` / `bundle-proxy`（无卷，新机直接起）。
- 起服务顺序要按 v7 规则：op-geth → rollup-boost → op-node（用 `make flashblocks-up` + `make flashblocks-recover`，见 RUNBOOK §4/§6）。
- ⚠️ **方式 B（纯 L1 重建）对 op-rbuilder 不友好**：op-rbuilder 中途接入已有链会 sync 错位（见 `STRESS_TEST_REPORT_V7.md` §13），此时优先用方式 A 搬 `rbuilder-data` 卷；搬不了则需让其重新 sync（数小时，但不丢 op-geth 链数据）。

---

## 10. 结果记录表（每次迁移演练填一行）

| 日期 | 方式(A/B) | 老机 head | 新机 head | genesis一致 | safe恢复(s) | V1-V8 | 结论 | 备注 |
|---|---|---:|---:|:---:|---:|---|---|---|
|   |   |   |   |   |   |   |   |   |

### 10.1 总体判定

- [ ] genesis hash / chainId 跨机一致（V1/V2）
- [ ] head 不归零并追上老机（V3）
- [ ] safe head 恢复增长（V4）
- [ ] op-node 无红线日志（V6）
- [ ] 历史 tx 可查（V5）
- [ ] 老机可安全退役（新机稳定 ≥ 1h）
