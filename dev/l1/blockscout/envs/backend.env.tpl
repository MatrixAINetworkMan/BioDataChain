# =============================================================================
# Blockscout backend (standard Ethereum flavor) — MyChain L1
#
# 这个文件经 envsubst 渲染成 envs/backend.env 后被 docker-compose 加载。
# 渲染脚本：dev/l1/scripts/blockscout-up.sh
#
# 跟 dev/blockscout/envs/backend.env.tpl 的关键差异：
#   - 不设 CHAIN_TYPE=optimism（这条 L1 不是 rollup）
#   - 没有任何 INDEXER_OPTIMISM_* 字段
#   - JSONRPC URL 指向 geth-l1（同一个 docker network 下的 hostname）
# =============================================================================

# -----------------------------------------------------------------------------
# 必须项：与 L1 geth 通讯
# -----------------------------------------------------------------------------
ETHEREUM_JSONRPC_VARIANT=geth
ETHEREUM_JSONRPC_HTTP_URL=http://geth-l1:8545
ETHEREUM_JSONRPC_TRACE_URL=http://geth-l1:8545
ETHEREUM_JSONRPC_WS_URL=ws://geth-l1:8546
ETHEREUM_JSONRPC_HTTP_TIMEOUT=30
ETHEREUM_JSONRPC_DISABLE_ARCHIVE_BALANCES=false

DATABASE_URL=postgresql://blockscout:blockscout@db:5432/blockscout
ECTO_USE_SSL=false

ACCOUNT_REDIS_URL=redis://redis:6379
CACHE_REDIS_URL=redis://redis:6379

# 必须 >= 64 字符；dev 用固定值，prod 必须改
SECRET_KEY_BASE=${BS_SECRET_KEY_BASE}

PORT=4000
MIX_ENV=prod

# -----------------------------------------------------------------------------
# 链元信息
# -----------------------------------------------------------------------------
CHAIN_ID=${L1_CHAIN_ID}
NETWORK=${L1_NETWORK_SHORT_NAME}
SUBNETWORK=${L1_NETWORK_NAME}
COIN=ETH
COIN_NAME=ETH
NETWORK_PATH=/

# -----------------------------------------------------------------------------
# 关掉 dev 用不上的东西
# -----------------------------------------------------------------------------
DISABLE_INDEXER=false
DISABLE_REALTIME_INDEXER=false
DISABLE_WEBAPP=false
DISABLE_EXCHANGE_RATES=true
EXCHANGE_RATES_FETCH_BTC_PRICE=false
EXCHANGE_RATES_FETCH_ETH_PRICE=false
INDEXER_DISABLE_BEACON_BLOCK_FETCHER=true
INDEXER_DISABLE_PENDING_TRANSACTIONS_FETCHER=false
INDEXER_DISABLE_INTERNAL_TRANSACTIONS_FETCHER=false

RE_CAPTCHA_DISABLED=true
SHOW_PRICE_CHART=false
SHOW_TXS_CHART=true
SHOW_BLOCKSCOUT_REWARDS=false
SUPPORTED_CHAINS=[]
DISPLAY_TOKEN_ICONS=false

# -----------------------------------------------------------------------------
# 微服务
# -----------------------------------------------------------------------------
MICROSERVICE_SC_VERIFIER_URL=http://smart-contract-verifier:8050
MICROSERVICE_SC_VERIFIER_TYPE=sc_verifier
MICROSERVICE_SC_VERIFIER_ENABLED=true

# -----------------------------------------------------------------------------
# 对外身份（Phoenix 用它生成绝对 URL + 校验 WebSocket Origin）
# 反代模式：BS_PUBLIC_HOST=l1.example.com，BS_PUBLIC_PROTOCOL=https
# 直连模式：BS_PUBLIC_HOST=<IP>，BS_PUBLIC_PROTOCOL=http
# -----------------------------------------------------------------------------
BLOCKSCOUT_HOST=${BS_PUBLIC_HOST}
BLOCKSCOUT_PROTOCOL=${BS_PUBLIC_PROTOCOL}

# 直连模式 port 默认 80/443 跟实际端口对不上，dev 一律关 origin 校验
CHECK_ORIGIN=false

# -----------------------------------------------------------------------------
# API
# -----------------------------------------------------------------------------
API_URL=/api
API_RATE_LIMIT_DISABLED=true
API_RATE_LIMIT_TIME_INTERVAL=1m
API_RATE_LIMIT_BY_IP=10000
