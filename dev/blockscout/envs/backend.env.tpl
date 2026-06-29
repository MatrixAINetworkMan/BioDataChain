# =============================================================================
# Blockscout backend (Optimism flavor) — 模板文件
#
# 这个文件经 envsubst 渲染成 envs/backend.env 后被 docker-compose 加载。
# 渲染脚本：dev/scripts/blockscout-up.sh
#
# 变量来源：
#   ${PUBLIC_HOST}, ${L2_*}, ${ANVIL_*} 等            <-- dev/.env
#   ${SYSTEM_CONFIG_PROXY}, ${OPTIMISM_PORTAL_PROXY},
#   ${DISPUTE_GAME_FACTORY_PROXY}, ${BATCHER_ADDRESS} <-- workdir/shared/l1-addresses.env
# =============================================================================

# -----------------------------------------------------------------------------
# 必须项：与本机服务通讯
# -----------------------------------------------------------------------------
ETHEREUM_JSONRPC_VARIANT=geth
# v6 默认指 op-geth（finalized 视图）。
# v7 (Flashblocks) 通过 .env.flashblocks 把 BLOCKSCOUT_INDEXER_RPC 改成
# flashblocks-rpc，让 indexer 看 pre-confirmation 数据（D3=force_d3b 决策）。
# Reorg 风险与回退预案见 docs/PHASE2_INTEGRATION.md §6。
#
# 默认值在 blockscout-up.sh 里 shell-level export（envsubst 不支持 :- 语法），
# 所以这里直接写 ${VAR}，不写 :-fallback。
ETHEREUM_JSONRPC_HTTP_URL=${BLOCKSCOUT_INDEXER_RPC}
# Trace 永远走 op-geth：pre-confirmation block 上 trace 没意义（block 还没 finalize）
ETHEREUM_JSONRPC_TRACE_URL=${BLOCKSCOUT_INDEXER_TRACE_RPC}
# WS 永远走 op-geth：flashblocks-rpc 的 WS subscribe 实现还不全
ETHEREUM_JSONRPC_WS_URL=${BLOCKSCOUT_INDEXER_WS}
ETHEREUM_JSONRPC_HTTP_TIMEOUT=30
ETHEREUM_JSONRPC_DISABLE_ARCHIVE_BALANCES=false

DATABASE_URL=postgresql://blockscout:blockscout@db:5432/blockscout
ECTO_USE_SSL=false

ACCOUNT_REDIS_URL=redis://redis:6379
CACHE_REDIS_URL=redis://redis:6379

# 必须 >= 64 字符；dev 用固定值，prod 必须改
SECRET_KEY_BASE=${BLOCKSCOUT_SECRET_KEY_BASE}

PORT=4000
MIX_ENV=prod

# -----------------------------------------------------------------------------
# 链元信息（前端会从 backend 拉这些显示）
# -----------------------------------------------------------------------------
CHAIN_ID=${L2_CHAIN_ID}
NETWORK=MAN
SUBNETWORK=MAN Dev
COIN=${NATIVE_TOKEN_SYMBOL}
COIN_NAME=${NATIVE_TOKEN_SYMBOL}
NETWORK_PATH=/

# -----------------------------------------------------------------------------
# Optimism rollup 索引（CGT v2，超过本字段会触发 L1↔L2 cross-chain 索引）
# -----------------------------------------------------------------------------
CHAIN_TYPE=optimism

INDEXER_OPTIMISM_L1_RPC=http://anvil:8545
INDEXER_OPTIMISM_L1_RPC_HISTORICAL_BLOCKS_RANGE=250
INDEXER_OPTIMISM_L1_BLOCK_DURATION=${L1_BLOCK_TIME}

INDEXER_OPTIMISM_L1_PORTAL_CONTRACT=${OPTIMISM_PORTAL_PROXY}
INDEXER_OPTIMISM_L1_SYSTEM_CONFIG_CONTRACT=${SYSTEM_CONFIG_PROXY}
INDEXER_OPTIMISM_L1_OUTPUT_ROOTS_CONTRACT=${DISPUTE_GAME_FACTORY_PROXY}
INDEXER_OPTIMISM_L1_DISPUTE_GAME_INDEXING_ENABLED=true

# Batch / DA 配置（dev 用 calldata，没有 4844 blob）
INDEXER_OPTIMISM_L1_BATCH_SUBMITTER=${BATCHER_ADDRESS}
INDEXER_OPTIMISM_L1_BATCH_INBOX=${BATCH_INBOX_ADDRESS}
INDEXER_OPTIMISM_L1_BATCH_BLOCKSCOUT_BLOBS_API_URL=
INDEXER_OPTIMISM_L1_BATCH_BLOCKS_CHUNK_SIZE=4

# Deposit transaction type = 0x7E
INDEXER_OPTIMISM_L1_DEPOSITS_BATCH_SIZE=10
INDEXER_OPTIMISM_L1_DEPOSITS_TRANSACTION_TYPE=126

INDEXER_OPTIMISM_L2_BATCH_GENESIS_BLOCK_NUMBER=0
INDEXER_OPTIMISM_L2_WITHDRAWALS_START_BLOCK=1
INDEXER_OPTIMISM_L2_DEPOSIT_FINALIZATION_INTERVAL=10s

# -----------------------------------------------------------------------------
# 关掉 dev 用不上的东西，省 RAM 省日志
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
# 微服务（验证器 / 函数签名解码）
# -----------------------------------------------------------------------------
MICROSERVICE_SC_VERIFIER_URL=http://smart-contract-verifier:8050
MICROSERVICE_SC_VERIFIER_TYPE=sc_verifier
MICROSERVICE_SC_VERIFIER_ENABLED=true

MICROSERVICE_SIG_PROVIDER_URL=http://sig-provider:8043
MICROSERVICE_SIG_PROVIDER_ENABLED=true

# -----------------------------------------------------------------------------
# 对外身份（Phoenix 用它生成绝对 URL + 校验 WebSocket Origin）
#
# 必须设！不然实时推送会被 Phoenix 的 check_origin 拒掉（Origin 跟 endpoint :url
# 不匹配 → WS 握手 403），前端表面上能打开但所有实时数据都不刷新，必须手动 F5。
#
# BS_PUBLIC_* 一组变量由 blockscout-up.sh 算好：
#   - 反代模式：BS_PUBLIC_HOST=demo.example.com，BS_PUBLIC_PROTOCOL=https
#   - 直连模式：BS_PUBLIC_HOST=<IP>，BS_PUBLIC_PROTOCOL=http
# -----------------------------------------------------------------------------
BLOCKSCOUT_HOST=${BS_PUBLIC_HOST}
BLOCKSCOUT_PROTOCOL=${BS_PUBLIC_PROTOCOL}

# 直连模式下 endpoint :port 默认 80/443 跟实际公网端口（4000）对不上，check_origin
# 仍可能挂；dev 一律关掉这个校验，反正不是面向公网用户的环境。
CHECK_ORIGIN=false

# -----------------------------------------------------------------------------
# API
# -----------------------------------------------------------------------------
API_URL=/api
API_RATE_LIMIT_DISABLED=true
API_RATE_LIMIT_TIME_INTERVAL=1m
API_RATE_LIMIT_BY_IP=10000
