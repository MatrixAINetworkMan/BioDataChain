// bundle-proxy 配置：全部从环境变量读，启动时一次性 freeze。
//
// 默认值故意贴近 dev/.env.flashblocks 里的设置，让 docker-compose 不传任何 env
// 也能直连 mychain v7 stack 跑起来。生产环境务必显式传 BUNDLE_BLOCK_OFS / IN_FLIGHT_LIMIT。

const env = (key, def) => (process.env[key] !== undefined ? process.env[key] : def);
const num = (key, def) => parseInt(env(key, String(def)), 10);

export const config = Object.freeze({
  // === Server ===
  PORT:           num('PORT', 9560),
  METRICS_PORT:   num('METRICS_PORT', 9561),
  HOST:           env('HOST', '0.0.0.0'),
  LOG_LEVEL:      env('LOG_LEVEL', 'info'),

  // === Upstream ===
  // op-rbuilder eth_sendBundle 入口（mychain v7 容器内）
  RBUILDER_URL:   env('RBUILDER_URL', 'http://op-rbuilder:8545'),
  // op-geth :8545（fallback：rbuilder down 时退化到 raw tx；read 也走这里）
  OPGETH_URL:     env('OPGETH_URL', 'http://op-geth:8545'),
  // flashblocks-rpc：read pre-confirmation 视图（eth_call / eth_getBalance / eth_getTransactionByHash）
  FLASHBLOCKS_RPC_URL: env('FLASHBLOCKS_RPC_URL', 'http://flashblocks-rpc:8545'),
  // 读方法走哪个：'flashblocks' (pre-confirm 快) | 'opgeth' (finalized 稳)
  READ_TARGET:    env('READ_TARGET', 'flashblocks'),

  // === HTTP client (undici keep-alive) ===
  // Phase 1.5 实测：32 连接 × 10 pipelining 撑得住 1000+ TPS。
  HTTP_POOL_SIZE: num('HTTP_POOL_SIZE', 32),
  HTTP_PIPELINE:  num('HTTP_PIPELINE', 10),
  HTTP_TIMEOUT_MS: num('HTTP_TIMEOUT_MS', 5000),

  // === Bundle 适配 ===
  // bundle.blockNumber = head + N。Phase 1.6 实测 N=1 在高 TPS 下因 RPC 排队 ≥ 1s
  // 而被 builder silent-drop（bundle 已过期）。N=10 给 10s 窗口。
  BUNDLE_BLOCK_OFS: num('BUNDLE_BLOCK_OFS', 10),
  // chainId 缓存的 head 多久 refresh 一次（避免每个 bundle 都查 head）
  HEAD_REFRESH_MS:  num('HEAD_REFRESH_MS', 200),

  // === fail-fast ===
  // in-flight 上限（同时未返的 sendRawTransaction 数）。超过即 -32000。
  // Phase 1 实测 op-rbuilder 800 TPS 稳态 + 1s 平均 RPC 延迟 = 800 in-flight，
  // 给 1.25x 余量 = 1000。生产部署看 Grafana 调。
  IN_FLIGHT_LIMIT: num('IN_FLIGHT_LIMIT', 1000),

  // upstream 失败重试：M1 不重试（fail-fast 优先），M2 评估
  UPSTREAM_RETRY:  num('UPSTREAM_RETRY', 0),

  // === Fallback ===
  // op-rbuilder 5xx / timeout / connect refused 时是否 fallback 到 op-geth raw tx
  ENABLE_FALLBACK: env('ENABLE_FALLBACK', 'true') === 'true',
  // 连续多少次 rbuilder 失败后开启 fallback 模式（防偶发抖动 fallback）
  FALLBACK_THRESHOLD: num('FALLBACK_THRESHOLD', 5),
  // fallback 持续多久后再尝试 rbuilder（半开熔断）
  FALLBACK_HALF_OPEN_MS: num('FALLBACK_HALF_OPEN_MS', 5000),

  // === chain ===
  CHAIN_ID: num('CHAIN_ID', 175700),
});

export function dumpConfig() {
  const safe = { ...config };
  return JSON.stringify(safe, null, 2);
}
