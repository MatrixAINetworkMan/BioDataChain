# =============================================================================
# Blockscout frontend (Next.js) — 模板文件
#
# 这个文件经 envsubst 渲染成 envs/frontend.env 后被 docker-compose 加载。
# 渲染脚本：dev/scripts/blockscout-up.sh
#
# 注意：所有 NEXT_PUBLIC_* 变量都会被打进浏览器 JS bundle，
#       所以 *_HOST 必须是浏览器可达的地址（域名 / 外网 IP），不是 docker hostname。
#
# BS_PUBLIC_* 一组变量由 blockscout-up.sh 根据 BLOCKSCOUT_PUBLIC_URL 算好：
#   - 反代模式（设了 BLOCKSCOUT_PUBLIC_URL）：所有字段都指向那个域名 + HTTPS
#   - 直连模式（没设）：指向 ${PUBLIC_HOST}:${BLOCKSCOUT_PORT/API_PORT}
# =============================================================================

# -----------------------------------------------------------------------------
# 后端 API 地址（浏览器侧的 ajax 走这里）
# -----------------------------------------------------------------------------
NEXT_PUBLIC_API_HOST=${BS_PUBLIC_API_HOST}
NEXT_PUBLIC_API_PROTOCOL=${BS_PUBLIC_API_PROTOCOL}
NEXT_PUBLIC_API_PORT=${BS_PUBLIC_API_PORT}
NEXT_PUBLIC_API_BASE_PATH=/
NEXT_PUBLIC_API_WEBSOCKET_PROTOCOL=${BS_WS_PROTOCOL}

# -----------------------------------------------------------------------------
# 自身（前端）地址
# -----------------------------------------------------------------------------
NEXT_PUBLIC_APP_HOST=${BS_PUBLIC_HOST}
NEXT_PUBLIC_APP_PROTOCOL=${BS_PUBLIC_PROTOCOL}
NEXT_PUBLIC_APP_PORT=${BS_PUBLIC_PORT}
NEXT_PUBLIC_APP_ENV=development

# -----------------------------------------------------------------------------
# 链元信息
# -----------------------------------------------------------------------------
NEXT_PUBLIC_NETWORK_NAME=MAN Dev
NEXT_PUBLIC_NETWORK_SHORT_NAME=MAN
NEXT_PUBLIC_NETWORK_ID=${L2_CHAIN_ID}
NEXT_PUBLIC_NETWORK_RPC_URL=http://${PUBLIC_HOST}:${L2_RPC_PORT}
NEXT_PUBLIC_NETWORK_CURRENCY_NAME=${NATIVE_TOKEN_NAME}
NEXT_PUBLIC_NETWORK_CURRENCY_SYMBOL=${NATIVE_TOKEN_SYMBOL}
NEXT_PUBLIC_NETWORK_CURRENCY_DECIMALS=18

# -----------------------------------------------------------------------------
# 链 logo / icon（由 frontend 自己 serve，文件挂在 ./assets/）
#   - LOGO   = 横向品牌图，左上角 header 主位
#   - ICON   = 方形小图，钱包/选择器里小徽标
#   - *_DARK = 深色模式变体；没有就指回同一张
# 想换图：把 ./assets/man.svg 替换掉，或改这里的文件名（man1.svg / man2.svg）
# -----------------------------------------------------------------------------
NEXT_PUBLIC_NETWORK_LOGO=${BS_PUBLIC_BASE_URL}/assets/network/logo.svg
NEXT_PUBLIC_NETWORK_LOGO_DARK=${BS_PUBLIC_BASE_URL}/assets/network/logo.svg
NEXT_PUBLIC_NETWORK_ICON=${BS_PUBLIC_BASE_URL}/assets/network/icon.svg
NEXT_PUBLIC_NETWORK_ICON_DARK=${BS_PUBLIC_BASE_URL}/assets/network/icon.svg

# -----------------------------------------------------------------------------
# Optimism rollup UI（让 deposit / withdrawal / L1↔L2 tab 出来）
# NEXT_PUBLIC_ROLLUP_L2_WITHDRAWAL_URL 是 frontend 强制要求的非空字段——
# 真实部署应该指向 superbridge / 自建 withdrawal app；dev 没有就指回浏览器自身
# L1_BASE_URL 是 anvil 直连，没走 nginx，仍然 http://IP:8545
# -----------------------------------------------------------------------------
NEXT_PUBLIC_ROLLUP_TYPE=optimistic
NEXT_PUBLIC_ROLLUP_L1_BASE_URL=http://${PUBLIC_HOST}:${ANVIL_PORT}
NEXT_PUBLIC_ROLLUP_L2_WITHDRAWAL_URL=${BS_PUBLIC_BASE_URL}/

# -----------------------------------------------------------------------------
# 关 Ad / 关 indexing 警告条
# -----------------------------------------------------------------------------
NEXT_PUBLIC_AD_BANNER_PROVIDER=none
NEXT_PUBLIC_AD_TEXT_PROVIDER=none
NEXT_PUBLIC_HIDE_INDEXING_ALERT_BLOCKS=true
NEXT_PUBLIC_HIDE_INDEXING_ALERT_INT_TXS=true

# -----------------------------------------------------------------------------
# stats 微服务（首页 Daily transactions tile + Charts 页面所有图表）
# 浏览器直接 fetch ${NEXT_PUBLIC_STATS_API_HOST}/api/v1/lines/...，
# 所以这个 host 必须浏览器可达；stats 容器自身 CORS 已开 *。
# 反代模式：BLOCKSCOUT_STATS_PUBLIC_URL=https://stats.example.com
# 直连模式：自动指向 http://${PUBLIC_HOST}:${BLOCKSCOUT_STATS_PORT}
# -----------------------------------------------------------------------------
# HOST 必须只给 origin（scheme://host[:port]），路径前缀（如 /stats-api）走
# NEXT_PUBLIC_STATS_API_BASE_PATH，否则前端 new URL(/api/v1/..., HOST) 会把前缀丢掉。
NEXT_PUBLIC_STATS_API_HOST=${BS_STATS_ORIGIN}
NEXT_PUBLIC_STATS_API_BASE_PATH=${BS_STATS_BASE_PATH}

# -----------------------------------------------------------------------------
# 杂项 UI 设置
# -----------------------------------------------------------------------------
NEXT_PUBLIC_HOMEPAGE_CHARTS=["daily_txs"]
NEXT_PUBLIC_NETWORK_VERIFICATION_TYPE=validation
NEXT_PUBLIC_VIEWS_ADDRESS_HIDDEN_VIEWS=[]
NEXT_PUBLIC_VIEWS_BLOCK_HIDDEN_FIELDS=[]
NEXT_PUBLIC_VIEWS_TX_HIDDEN_FIELDS=[]
NEXT_PUBLIC_OG_DESCRIPTION=MAN Dev — OP Stack L2 with custom gas token (CGT v2)
# NEXT_PUBLIC_FOOTER_LINKS 留空 = 不设；frontend 把 "" 当 array 校验会爆，
# 真要加 footer 链接：NEXT_PUBLIC_FOOTER_LINKS=[{"text":"GitHub","url":"https://..."}]
