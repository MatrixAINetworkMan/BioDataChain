# bundle-proxy

> mychain v7 (Phase 2 Flashblocks) 接入层。把 dApp 的 `eth_sendRawTransaction` 适配成 op-rbuilder 的 `eth_sendBundle`，并在入口做 fail-fast。

## 角色

```
[dApp / SDK]
   │ eth_sendRawTransaction
   ▼
[bundle-proxy :9560] ── eth_sendBundle ──► [op-rbuilder :8545]
       │                                          │
       │ fallback                                 ▼
       └── eth_sendRawTransaction ──► [op-geth :8545]
```

详见 `docs/PHASE2_INTEGRATION.md`、`docs/PHASE2_BUNDLE_PROXY.md`。

## 快速开始（本地开发）

```bash
cd dev/bundle-proxy
npm install
npm run mock        # 终端 1：起 mock-rbuilder（端口 18545）
RBUILDER_URL=http://127.0.0.1:18545/rbuilder \
OPGETH_URL=http://127.0.0.1:18545/opgeth \
FLASHBLOCKS_RPC_URL=http://127.0.0.1:18545/flashblocks \
PORT=9560 \
  npm start          # 终端 2：起 bundle-proxy
```

测试：
```bash
npm run test:smoke   # 11 个端到端 smoke case，~2s
```

## 配置（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | 9560 | JSON-RPC 监听端口（dApp 接这里）|
| `METRICS_PORT` | 9561 | Prometheus 指标端口 |
| `RBUILDER_URL` | `http://op-rbuilder:8545` | 主上游（写）|
| `OPGETH_URL` | `http://op-geth:8545` | fallback + finalized 读 |
| `FLASHBLOCKS_RPC_URL` | `http://flashblocks-rpc:8545` | pre-confirmation 读 |
| `READ_TARGET` | `flashblocks` | 读路径默认走哪个：`flashblocks`/`opgeth` |
| `IN_FLIGHT_LIMIT` | 1000 | 同时未返的写请求上限，超即 -32000 |
| `BUNDLE_BLOCK_OFS` | 10 | bundle.blockNumber = head + N |
| `HTTP_POOL_SIZE` | 32 | undici 连接池（rbuilder）|
| `HTTP_PIPELINE` | 10 | 单连接 pipelined 请求数 |
| `HTTP_TIMEOUT_MS` | 5000 | 上游请求超时 |
| `ENABLE_FALLBACK` | true | rbuilder 失败时是否走 opgeth |
| `FALLBACK_THRESHOLD` | 5 | 连续失败 N 次开启熔断 |
| `FALLBACK_HALF_OPEN_MS` | 5000 | 熔断 OPEN→HALF_OPEN 等待时间 |
| `CHAIN_ID` | 175700 | mychain v7 L2 chainId |

## JSON-RPC method 路由

| method | 路由 | 备注 |
|---|---|---|
| `eth_sendRawTransaction` | rbuilder（适配为 bundle）| 失败 fallback opgeth |
| `eth_chainId` | 本地缓存 | startup 一次 |
| `eth_call`, `eth_getBalance`, ... | flashblocks-rpc / opgeth | 见 `READ_TARGET` |
| `debug_*`, `eth_getLogs`, `eth_getBlockByNumber` | opgeth | trace / 历史 block 必须 finalized |
| 其他未知 method | opgeth | SDK 兼容兜底 |

## fail-fast 设计

1. **in-flight counter**: 入口 `acquire()`，超限立刻 `-32000 Server overloaded`
2. **熔断器**: rbuilder 连续 5 次失败 → OPEN，5s 后 HALF_OPEN，单笔试探
3. **不重试**: 单次请求失败立即返错给客户端（client retry 让客户端自己决定）

## 监控指标

GET `:9561/metrics` 暴露：

- `bundle_proxy_rpc_total{method,outcome}` — 总请求数
- `bundle_proxy_rpc_latency_ms{method,outcome}` — p50/p95/p99
- `bundle_proxy_upstream_latency_ms{target,method,outcome}` — 上游延迟
- `bundle_proxy_inflight` — 当前 in-flight
- `bundle_proxy_circuit_state` — 熔断器状态（0/1/2）
- `bundle_proxy_fallback_total` — fallback 触发次数
- `bundle_proxy_head_stale_ms` — head 上次刷新距今

## 故障注入（mock-rbuilder）

`npm run mock` 起 mock 后，HTTP GET 控制：

| URL | 效果 |
|---|---|
| `GET /control/rbuilder/down` | rbuilder 接下来都返 503 |
| `GET /control/rbuilder/up` | 恢复 |
| `GET /control/rbuilder/slow?ms=2000` | 每个请求加 2s 延迟 |
| `GET /control/rbuilder/normal` | 清掉延迟 |
| `GET /control/opgeth/down` | opgeth fallback 也挂 |
| `GET /control/opgeth/up` | 恢复 |

## Docker 镜像

```bash
docker build -t mychain/bundle-proxy:0.1.0 -f Dockerfile .
docker run --rm -p 9560:9560 -p 9561:9561 \
  -e RBUILDER_URL=http://host.docker.internal:8545 \
  -e OPGETH_URL=http://host.docker.internal:9545 \
  mychain/bundle-proxy:0.1.0
```
