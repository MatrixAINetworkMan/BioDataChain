# =============================================================================
# Blockscout backend (Optimism flavor) —— 独立部署模板
# 经 install.sh 用 envsubst 渲染成 envs/backend.env 后被 docker-compose 加载。
# 变量全部来自本目录 .env。
# =============================================================================

# -----------------------------------------------------------------------------
# L2 链 RPC（指向远程 op-geth；indexer 的命根子）
# -----------------------------------------------------------------------------
ETHEREUM_JSONRPC_VARIANT=geth
ETHEREUM_JSONRPC_HTTP_URL=${L2_RPC_HTTP}
ETHEREUM_JSONRPC_TRACE_URL=${L2_RPC_TRACE}
ETHEREUM_JSONRPC_WS_URL=${L2_RPC_WS}
ETHEREUM_JSONRPC_HTTP_TIMEOUT=30
ETHEREUM_JSONRPC_DISABLE_ARCHIVE_BALANCES=false

# -----------------------------------------------------------------------------
# 本机内部服务
# -----------------------------------------------------------------------------
DATABASE_URL=postgresql://blockscout:blockscout@db:5432/blockscout
ECTO_USE_SSL=false
# v11+ 新增 ECTO_SSL_MODE，默认 require 且优先级高于 ECTO_USE_SSL；本地 postgres 未开 SSL，必须显式 disable，
# 否则 backend 会报 "(Postgrex.Error) ssl not available" 建表失败、crash-loop。
ECTO_SSL_MODE=disable
ACCOUNT_REDIS_URL=redis://redis:6379
CACHE_REDIS_URL=redis://redis:6379

SECRET_KEY_BASE=${BLOCKSCOUT_SECRET_KEY_BASE}
PORT=4000
MIX_ENV=prod

# -----------------------------------------------------------------------------
# 链元信息
# -----------------------------------------------------------------------------
CHAIN_ID=${L2_CHAIN_ID}
NETWORK=${NATIVE_TOKEN_NAME}
SUBNETWORK=${NATIVE_TOKEN_NAME} Chain
COIN=${NATIVE_TOKEN_SYMBOL}
COIN_NAME=${NATIVE_TOKEN_SYMBOL}
NETWORK_PATH=/

# -----------------------------------------------------------------------------
# Optimism rollup 跨链索引（指向远程 L1）
# -----------------------------------------------------------------------------
CHAIN_TYPE=optimism
INDEXER_OPTIMISM_L1_RPC=${L1_RPC}
INDEXER_OPTIMISM_L1_RPC_HISTORICAL_BLOCKS_RANGE=250
INDEXER_OPTIMISM_L1_BLOCK_DURATION=${L1_BLOCK_TIME}
INDEXER_OPTIMISM_L1_PORTAL_CONTRACT=${OPTIMISM_PORTAL_PROXY}
INDEXER_OPTIMISM_L1_SYSTEM_CONFIG_CONTRACT=${SYSTEM_CONFIG_PROXY}
INDEXER_OPTIMISM_L1_OUTPUT_ROOTS_CONTRACT=${DISPUTE_GAME_FACTORY_PROXY}
INDEXER_OPTIMISM_L1_DISPUTE_GAME_INDEXING_ENABLED=true
INDEXER_OPTIMISM_L1_BATCH_SUBMITTER=${BATCHER_ADDRESS}
INDEXER_OPTIMISM_L1_BATCH_INBOX=${BATCH_INBOX_ADDRESS}
INDEXER_OPTIMISM_L1_BATCH_BLOCKSCOUT_BLOBS_API_URL=
INDEXER_OPTIMISM_L1_BATCH_BLOCKS_CHUNK_SIZE=4
INDEXER_OPTIMISM_L1_DEPOSITS_BATCH_SIZE=10
INDEXER_OPTIMISM_L1_DEPOSITS_TRANSACTION_TYPE=126
INDEXER_OPTIMISM_L2_BATCH_GENESIS_BLOCK_NUMBER=${INDEXER_OPTIMISM_L2_BATCH_GENESIS_BLOCK_NUMBER}
INDEXER_OPTIMISM_L2_WITHDRAWALS_START_BLOCK=1
INDEXER_OPTIMISM_L2_DEPOSIT_FINALIZATION_INTERVAL=10s

# -----------------------------------------------------------------------------
# 省 RAM / 省日志
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
MICROSERVICE_SIG_PROVIDER_URL=http://sig-provider:8043
MICROSERVICE_SIG_PROVIDER_ENABLED=true

# -----------------------------------------------------------------------------
# 对外身份（Phoenix 生成绝对 URL + 校验 WS Origin）
# -----------------------------------------------------------------------------
BLOCKSCOUT_HOST=${BS_PUBLIC_HOST}
BLOCKSCOUT_PROTOCOL=${BS_PUBLIC_PROTOCOL}
CHECK_ORIGIN=false

API_URL=/api
API_RATE_LIMIT_DISABLED=true
API_RATE_LIMIT_TIME_INTERVAL=1m
API_RATE_LIMIT_BY_IP=10000
