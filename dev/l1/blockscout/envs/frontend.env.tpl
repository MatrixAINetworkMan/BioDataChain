# =============================================================================
# Blockscout frontend (Next.js) — MyChain L1
#
# 所有 NEXT_PUBLIC_* 都会被打进浏览器 bundle，*_HOST 必须浏览器可达
#
# BS_PUBLIC_* 一组变量由 dev/l1/scripts/blockscout-up.sh 算好：
#   - 反代模式（设了 BS_PUBLIC_URL）：所有字段指向那个域名 + HTTPS
#   - 直连模式（没设）：指向 ${PUBLIC_HOST}:${BS_PORT/API_PORT}
# =============================================================================

# 后端 API 地址（浏览器 ajax）
NEXT_PUBLIC_API_HOST=${BS_PUBLIC_API_HOST}
NEXT_PUBLIC_API_PROTOCOL=${BS_PUBLIC_API_PROTOCOL}
NEXT_PUBLIC_API_PORT=${BS_PUBLIC_API_PORT}
NEXT_PUBLIC_API_BASE_PATH=/
NEXT_PUBLIC_API_WEBSOCKET_PROTOCOL=${BS_WS_PROTOCOL}

# 前端自身
NEXT_PUBLIC_APP_HOST=${BS_PUBLIC_HOST}
NEXT_PUBLIC_APP_PROTOCOL=${BS_PUBLIC_PROTOCOL}
NEXT_PUBLIC_APP_PORT=${BS_PUBLIC_PORT}
NEXT_PUBLIC_APP_ENV=development

# -----------------------------------------------------------------------------
# 链元信息
# -----------------------------------------------------------------------------
NEXT_PUBLIC_NETWORK_NAME=${L1_NETWORK_NAME}
NEXT_PUBLIC_NETWORK_SHORT_NAME=${L1_NETWORK_SHORT_NAME}
NEXT_PUBLIC_NETWORK_ID=${L1_CHAIN_ID}
NEXT_PUBLIC_NETWORK_RPC_URL=${BS_RPC_URL}
NEXT_PUBLIC_NETWORK_CURRENCY_NAME=Ether
NEXT_PUBLIC_NETWORK_CURRENCY_SYMBOL=ETH
NEXT_PUBLIC_NETWORK_CURRENCY_DECIMALS=18

# 链 logo / icon
NEXT_PUBLIC_NETWORK_LOGO=${BS_PUBLIC_BASE_URL}/assets/network/logo.svg
NEXT_PUBLIC_NETWORK_LOGO_DARK=${BS_PUBLIC_BASE_URL}/assets/network/logo.svg
NEXT_PUBLIC_NETWORK_ICON=${BS_PUBLIC_BASE_URL}/assets/network/icon.svg
NEXT_PUBLIC_NETWORK_ICON_DARK=${BS_PUBLIC_BASE_URL}/assets/network/icon.svg

# 关 Ad / 关 indexing 警告条
NEXT_PUBLIC_AD_BANNER_PROVIDER=none
NEXT_PUBLIC_AD_TEXT_PROVIDER=none
NEXT_PUBLIC_HIDE_INDEXING_ALERT_BLOCKS=true
NEXT_PUBLIC_HIDE_INDEXING_ALERT_INT_TXS=true

# Stats 微服务
#   _HOST 必须是 origin（protocol://host[:port]），不能含 path，否则 frontend 的
#   new URL() 解析时会丢掉 path 部分，请求被打到主域 /api/v1/... → backend 报 400。
#   path 部分单独写在 _BASE_PATH。
#     反代模式：_HOST=https://devl1.example.com, _BASE_PATH=/stats-api/
#     直连模式：_HOST=http://PUBLIC_HOST:8081,   _BASE_PATH=/
NEXT_PUBLIC_STATS_API_HOST=${BS_STATS_API_HOST}
NEXT_PUBLIC_STATS_API_BASE_PATH=${BS_STATS_API_BASE_PATH}

# -----------------------------------------------------------------------------
# 杂项 UI
# -----------------------------------------------------------------------------
NEXT_PUBLIC_HOMEPAGE_CHARTS=["daily_txs"]
NEXT_PUBLIC_NETWORK_VERIFICATION_TYPE=validation
NEXT_PUBLIC_VIEWS_ADDRESS_HIDDEN_VIEWS=[]
NEXT_PUBLIC_VIEWS_BLOCK_HIDDEN_FIELDS=[]
NEXT_PUBLIC_VIEWS_TX_HIDDEN_FIELDS=[]
NEXT_PUBLIC_OG_DESCRIPTION=MAN L1 — self-hosted L1 chain explorer
