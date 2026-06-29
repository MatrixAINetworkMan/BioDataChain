# =============================================================================
# Blockscout frontend (Next.js) —— 独立部署模板
# 经 install.sh 用 envsubst 渲染成 envs/frontend.env。
#
# 注意：所有 NEXT_PUBLIC_* 会被打进浏览器 JS bundle，*_HOST 必须是浏览器可达的
#       地址（域名 / 公网 IP），不是 docker hostname。
#
# BS_PUBLIC_* / BS_STATS_* 由 install.sh 根据 BLOCKSCOUT_PUBLIC_URL /
# BLOCKSCOUT_STATS_PUBLIC_URL 算好。
# =============================================================================

# 后端 API（浏览器侧 ajax）
NEXT_PUBLIC_API_HOST=${BS_PUBLIC_API_HOST}
NEXT_PUBLIC_API_PROTOCOL=${BS_PUBLIC_API_PROTOCOL}
NEXT_PUBLIC_API_PORT=${BS_PUBLIC_API_PORT}
NEXT_PUBLIC_API_BASE_PATH=/
NEXT_PUBLIC_API_WEBSOCKET_PROTOCOL=${BS_WS_PROTOCOL}

# 前端自身地址
NEXT_PUBLIC_APP_HOST=${BS_PUBLIC_HOST}
NEXT_PUBLIC_APP_PROTOCOL=${BS_PUBLIC_PROTOCOL}
NEXT_PUBLIC_APP_PORT=${BS_PUBLIC_PORT}
NEXT_PUBLIC_APP_ENV=production

# 链元信息
NEXT_PUBLIC_NETWORK_NAME=${NATIVE_TOKEN_NAME} Chain
NEXT_PUBLIC_NETWORK_SHORT_NAME=${NATIVE_TOKEN_NAME}
NEXT_PUBLIC_NETWORK_ID=${L2_CHAIN_ID}
# 钱包「Add network」展示给用户的公网 RPC（必须 HTTPS）
NEXT_PUBLIC_NETWORK_RPC_URL=${L2_RPC_PUBLIC_URL}
NEXT_PUBLIC_NETWORK_CURRENCY_NAME=${NATIVE_TOKEN_NAME}
NEXT_PUBLIC_NETWORK_CURRENCY_SYMBOL=${NATIVE_TOKEN_SYMBOL}
NEXT_PUBLIC_NETWORK_CURRENCY_DECIMALS=18

# logo / icon
# ⚠️ 用 file:// 指向容器内挂载的本地文件，不能用 http(s) 公网 URL！
#   v2.8.0 起 entrypoint 的 download_assets.sh 会在「启动时」下载这些 URL，下不到就硬 exit 1。
#   而这些 asset 本就是前端 app 自己 serve 的，启动时 app 还没起来（鸡生蛋）+ 容器访问公网域名
#   有 NAT hairpin 问题 → 必然下载失败 → 前端 502。
#   实际浏览器端 logo 永远从本地 /assets/configs/network_logo.svg 伺服（见 configs/app/utils.ts
#   buildExternalAssetFilePath：路径由变量名推导，与此处的值无关），文件由 docker-compose 挂死。
#   所以这里用 file:// 让 download 步骤变成本地 cp（不走网络），扩展名仍能被 new URL() 解析出 svg。
NEXT_PUBLIC_NETWORK_LOGO=file:///app/public/assets/network/logo.svg
NEXT_PUBLIC_NETWORK_LOGO_DARK=file:///app/public/assets/network/logo.svg
NEXT_PUBLIC_NETWORK_ICON=file:///app/public/assets/network/icon.svg
NEXT_PUBLIC_NETWORK_ICON_DARK=file:///app/public/assets/network/icon.svg

# Optimism rollup UI（deposit / withdrawal / L1↔L2 tab）
NEXT_PUBLIC_ROLLUP_TYPE=optimistic
# ⚠️ v2.7.0 起 NEXT_PUBLIC_ROLLUP_L1_BASE_URL 被移除，改用 NEXT_PUBLIC_ROLLUP_PARENT_CHAIN（JSON）。
#   还设旧变量会被 envs-validator 判 "Congruity check failed" → 前端 exit 1。
#   baseUrl 必填，理想值是「L1 区块浏览器」地址（用于 L2 deposit/withdrawal 页里跳 L1 tx）；
#   目前没有独立的 L1 explorer 变量，暂沿用 L1_RPC 保持与旧版等价（L1 tx 链接指向 RPC，
#   要让链接可点请把 baseUrl 换成真正的 L1 浏览器 URL，如 https://devl1.example.com）。
NEXT_PUBLIC_ROLLUP_PARENT_CHAIN={'baseUrl':'${L1_RPC}'}
NEXT_PUBLIC_ROLLUP_L2_WITHDRAWAL_URL=${BS_PUBLIC_BASE_URL}/

# 关广告 / 关 indexing 警告条
NEXT_PUBLIC_AD_BANNER_PROVIDER=none
NEXT_PUBLIC_AD_TEXT_PROVIDER=none
NEXT_PUBLIC_HIDE_INDEXING_ALERT_BLOCKS=true
NEXT_PUBLIC_HIDE_INDEXING_ALERT_INT_TXS=true

# stats 微服务：HOST 只给 origin，路径前缀走 BASE_PATH（详见链仓库注释）
NEXT_PUBLIC_STATS_API_HOST=${BS_STATS_ORIGIN}
NEXT_PUBLIC_STATS_API_BASE_PATH=${BS_STATS_BASE_PATH}

# 杂项 UI
NEXT_PUBLIC_HOMEPAGE_CHARTS=["daily_txs"]
NEXT_PUBLIC_NETWORK_VERIFICATION_TYPE=validation
NEXT_PUBLIC_VIEWS_ADDRESS_HIDDEN_VIEWS=[]
NEXT_PUBLIC_VIEWS_BLOCK_HIDDEN_FIELDS=[]
NEXT_PUBLIC_VIEWS_TX_HIDDEN_FIELDS=[]
NEXT_PUBLIC_OG_DESCRIPTION=${NATIVE_TOKEN_NAME} Chain Explorer
