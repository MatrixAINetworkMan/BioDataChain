# restart-test —— 三台机各自本地运行的重启测试脚本

无需 SSH。把整个仓库（或这个 `docs/restart-test/` 目录 + `docs/` 同级）拷到每台机器，
**在对应机器上本地运行该机器的脚本**。脚本只用 `docker` + `curl` + `jq`。

## 哪台机器跑哪个脚本

| 机器 | 角色 | 在该机运行 |
|---|---|---|
| **L1 机** | 独立 geth Clique（`dev/l1`） | `bash docs/restart-test/l1-restart-test.sh` |
| **链机** | op-geth/op-node/op-batcher/op-proposer/Flashblocks三件套/l1-proxy/bundle-proxy（`dev/`） | `bash docs/restart-test/chain-restart-test.sh` |
| **浏览器机** | blockscout-standalone（`dev/blockscout-standalone`） | `bash docs/restart-test/scan-restart-test.sh` |

> 三台机互不依赖，可同时各跑各的。建议顺序：先链机（覆盖最多模块），L1 机和浏览器机随后。

## 每个脚本做什么

1. 记录重启前基准（chainId / genesis hash / head / 一笔历史 tx）。
2. `docker restart` 目标容器（**非破坏性**，绝不 `down -v` / `clean`）。
3. 验收两条硬指标：
   - **能否恢复**：容器回 running + 链头恢复涨（L1 head / L2 unsafe head / 浏览器块号）。
   - **会不会丢数据**：仅对有持久卷的模块（L1-geth / op-geth / op-rbuilder / Blockscout）比对
     genesis hash 不变、head 不归零、历史 tx 可查；无状态模块标 `N/A`。
4. 结果打印到屏幕，并追加一行到 `docs/RESTART_TEST_RUN_<date>.md`。

## 用法

```bash
# L1 机
bash docs/restart-test/l1-restart-test.sh         # R08 docker restart
bash docs/restart-test/l1-restart-test.sh R09     # R09 make down && make up（重建容器，保留卷）

# 链机（默认跑全部安全用例，单点 rollup-boost 放最后）
bash docs/restart-test/chain-restart-test.sh
bash docs/restart-test/chain-restart-test.sh R03 R02   # 只跑指定用例
SMOKE=0 bash docs/restart-test/chain-restart-test.sh   # 跳过结尾 flashblocks-smoke

# 浏览器机
bash docs/restart-test/scan-restart-test.sh
```

## 环境变量（一般不用改，自动从各机 .env 读端口）

| 变量 | 默认 | 说明 |
|---|---|---|
| `L1_DIR` / `CHAIN_DIR` / `SCAN_DIR` | 仓库内对应目录 | 部署目录不在仓库内时覆盖 |
| `BENCH_TX` | 自动扫最近块 | 手动指定用于校验的历史 tx hash |
| `SMOKE` | `1` | 链机脚本结尾是否跑 `flashblocks-smoke` |
| `AUTO_RECOVER` | `0` | 链机：恢复失败时是否自动 `make flashblocks-recover` |
| `RUN_LOG` | `docs/RESTART_TEST_RUN_<date>.md` | 结果记录文件 |

## 不包含的（需人工 + 云盘快照，见 RESTART_TEST_RUNBOOK_V7.md §4.11/§4.12）

`systemctl restart docker` / `reboot` / hard reset / 网络分区 / 多机同挂 —— 这些破坏性或跨机操作
不放进自动脚本，按 RUNBOOK 手动执行。
