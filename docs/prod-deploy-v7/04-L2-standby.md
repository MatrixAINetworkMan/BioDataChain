# 机器 #4：L2 热备 sequencer（verifier → 故障切换）

> 角色：平时作为 **verifier（不出块）**跟随主 sequencer；主 sequencer 故障时 **promote 成 sequencer** 顶上（HA）。
> 跑与 #3 相同的栈，但 op-node **不开 sequencer**。

---

## ⚠️ 同样要走 proxy / Flashblocks 启动

热备将来要顶替主 sequencer，所以**必须装齐 Flashblocks 全栈（op-rbuilder+rollup-boost+bundle-proxy+l1-proxy）**，否则 promote 后达不到 1000+ TPS。区别只在：op-node 以 verifier 模式起（平时不出块）。

## 1. 硬件

**与 #3 主 sequencer 完全同档**（16 vCPU / 128 GB / NVMe 2–4 TB），保证顶上后性能一致。

## 2. 部署步骤

```bash
cd /data/code/mychain/dev
# 1) 复用 #3 拷来的 shared（绝不重新 deploy！）
tar xzf shared.tgz                 # 得到 workdir/shared + .env.flashblocks
# 2) 自己写 .env（L1 指向同一台 #1，密钥/PUBLIC_HOST 按本机）
cp .env.example .env && vim .env
#    COMPOSE_FILE / L1_RPC_URL_* / L1_PROXY_UPSTREAM 同 #3（指 #1 L1）
#    L2_BLOCK_TIME / L2_GAS_LIMIT / chainId 必须与 #3 一致
```

**关键：op-node 以 verifier 模式起（不加 `--sequencer.enabled=true`）**，并 p2p 连主 sequencer 同步 unsafe head。

- 在 `docker-compose.yml` 的 op-node command 里，本机**去掉/关闭** `--sequencer.enabled=true`（或用 override 文件覆盖），加 `--p2p.static=<#3 op-node enode>` 让它从主拉 unsafe 块。
- 起服务（用 FB_COMPOSE 路径，保证拿到 rollup-boost engine URL）：

```bash
make dev-up-flashblocks
# 注意：本机不应触发 deploy/init genesis —— 因为 workdir/shared 已存在且 op-geth datadir
# 复用拷来的链数据时直接 up。若是全新盘，确保 init-geth 用的是【拷来的 genesis.json】，
# 不要重新 op-deployer。稳妥做法：参照 docs/MACHINE_MIGRATION_RUNBOOK_V7.md §4（搬卷）或 §5（从 L1 重建）。
```

## 3. 验收（verifier 正常跟随）

```bash
curl -s -X POST localhost:9547 -d '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' -H content-type:application/json | jq .result
curl -s -X POST localhost:9547 -d '{"jsonrpc":"2.0","method":"admin_sequencerActive","params":[],"id":1}' -H content-type:application/json   # 期望 false
```

- unsafe/safe head 跟随 #3（差几个块正常）；
- `admin_sequencerActive=false`（平时不出块）；
- genesis hash / chainId 与 #3 完全一致。

## 4. 故障切换（promote 成 sequencer）

> 完整流程见 `docs/MACHINE_MIGRATION_RUNBOOK_V7.md` 与历史 handoff 演练。核心铁律：**永远只有一台在出块，切换必须先停旧、再起新，杜绝双 sequencer 分叉。**

```bash
# 1) 确认主 #3 已彻底停 sequencer（停 op-batcher + op-node，让其 batcher 先 flush）
#    在 #3： docker compose stop op-batcher && sleep 5 && docker compose stop op-node
# 2) 确认本机 verifier 已追平 #3 最后 unsafe head
# 3) 本机 promote：
curl -s -X POST localhost:9547 -d '{"jsonrpc":"2.0","method":"admin_startSequencer","params":[],"id":1}' -H content-type:application/json
#    （若 op-node 启动参数是 verifier，需切换为带 --sequencer.enabled 重启后再 startSequencer）
# 4) 起本机 op-batcher 往 L1 提交
docker compose start op-batcher
# 5) 切流量：通知 #8 LB 把 bundle-proxy 上游指向本机
```

## 5. 运维

- 监控 verifier 与主的 head 差值（持续拉大 = p2p/派生异常）。
- 定期演练故障切换（参照已验证过的 handoff 流程），确保 RTO 可控。
