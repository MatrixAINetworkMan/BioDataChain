#!/usr/bin/env bash
# 启动 L1 Blockscout 浏览器（7 个服务）
#
# 前置：L1 geth 已经跑起来（make up），docker network mychain-l1-net 存在
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; source .env; set +a

# -----------------------------------------------------------------------------
# 0) 前置检查
# -----------------------------------------------------------------------------
if ! docker network inspect mychain-l1-net >/dev/null 2>&1; then
  echo "❌ docker network mychain-l1-net 不存在。先 make up 启动 L1 geth" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q '^mychain-l1-geth$'; then
  echo "❌ L1 geth 容器没在跑。先 make up" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# 1) 算 BS_PUBLIC_* 变量
#
# 反代模式（推荐生产）：在 .env 设 BS_PUBLIC_URL=https://l1.example.com
#   → 所有浏览器侧 URL 都指向这个域名（HTTPS），API/WS 走同域 /api 路径，
#     需要外部反代（nginx/caddy）把 /api、/socket 转发到 backend 容器
# 直连模式（默认）：BS_PUBLIC_URL 留空
#   → 浏览器直接访问 http://${PUBLIC_HOST}:${BS_PORT}，
#     API/WS 走 http://${PUBLIC_HOST}:${BS_API_PORT}
# -----------------------------------------------------------------------------
: "${PUBLIC_HOST:?PUBLIC_HOST 必须设置（.env）}"
BS_PORT="${BS_PORT:-3001}"
BS_API_PORT="${BS_API_PORT:-4001}"
BS_STATS_PORT="${BS_STATS_PORT:-8081}"

if [[ -n "${BS_PUBLIC_URL:-}" ]]; then
  # 反代模式
  BS_PUBLIC_PROTOCOL="$(echo "$BS_PUBLIC_URL" | sed -E 's|^([a-z]+)://.*|\1|')"
  BS_PUBLIC_HOST="$(echo "$BS_PUBLIC_URL" | sed -E 's|^[a-z]+://([^/]+).*|\1|')"
  # Blockscout frontend 校验 PORT 必须是 number，反代模式下走 80/443 默认端口
  # （传空串会被 yup schema 转成 NaN → 启动校验 failed → 容器 crash loop）
  if [[ "$BS_PUBLIC_PROTOCOL" == "https" ]]; then
    BS_PUBLIC_PORT=443
    BS_PUBLIC_API_PORT=443
    BS_WS_PROTOCOL="wss"
  else
    BS_PUBLIC_PORT=80
    BS_PUBLIC_API_PORT=80
    BS_WS_PROTOCOL="ws"
  fi
  BS_PUBLIC_API_HOST="$BS_PUBLIC_HOST"
  BS_PUBLIC_API_PROTOCOL="$BS_PUBLIC_PROTOCOL"
  BS_PUBLIC_BASE_URL="$BS_PUBLIC_URL"
  # stats API：frontend 的 NEXT_PUBLIC_STATS_API_HOST **只接受 origin**
  # （含 path 会被 new URL() 解析时丢掉 → 请求落到主域 /api/v1/... → backend 报 400）
  # 所以 HOST 跟主域同源，path 部分单独走 BASE_PATH
  # 单独子域名场景：用户在 .env 设 BS_STATS_PUBLIC_URL=https://stats.example.com
  if [[ -n "${BS_STATS_PUBLIC_URL:-}" ]]; then
    BS_STATS_API_HOST="$BS_STATS_PUBLIC_URL"
    BS_STATS_API_BASE_PATH="/"
  else
    BS_STATS_API_HOST="$BS_PUBLIC_URL"
    BS_STATS_API_BASE_PATH="/stats-api/"
  fi
  # MetaMask 的 RPC URL（"Add to wallet" 按钮用）走同域 /rpc，
  # nginx 反代到本机 8545（见 nginx/devl1.example.com.conf）
  BS_RPC_URL="${BS_PUBLIC_URL}/rpc"
  echo "==> 反代模式：$BS_PUBLIC_URL  (RPC: $BS_RPC_URL, Stats: ${BS_STATS_API_HOST}${BS_STATS_API_BASE_PATH})"
else
  # 直连模式
  BS_PUBLIC_PROTOCOL="http"
  BS_PUBLIC_HOST="$PUBLIC_HOST"
  BS_PUBLIC_PORT="$BS_PORT"
  BS_PUBLIC_API_HOST="$PUBLIC_HOST"
  BS_PUBLIC_API_PROTOCOL="http"
  BS_PUBLIC_API_PORT="$BS_API_PORT"
  BS_PUBLIC_BASE_URL="http://${PUBLIC_HOST}:${BS_PORT}"
  BS_WS_PROTOCOL="ws"
  # 直连模式 stats 直接走 8081
  BS_STATS_API_HOST="http://${PUBLIC_HOST}:${BS_STATS_PORT}"
  BS_STATS_API_BASE_PATH="/"
  BS_RPC_URL="http://${PUBLIC_HOST}:${HTTP_PORT}"
  echo "==> 直连模式：frontend=http://${PUBLIC_HOST}:${BS_PORT}, api=http://${PUBLIC_HOST}:${BS_API_PORT}"
fi

# -----------------------------------------------------------------------------
# 2) 渲染 envs/backend.env + envs/frontend.env
# -----------------------------------------------------------------------------
export L1_CHAIN_ID L1_NETWORK_NAME PUBLIC_HOST HTTP_PORT
export L1_NETWORK_SHORT_NAME="${L1_NETWORK_SHORT_NAME:-${L1_NETWORK_NAME}}"
export BS_BACKEND_IMAGE="${BS_BACKEND_IMAGE:-ghcr.io/blockscout/blockscout:latest}"
export BS_FRONTEND_IMAGE="${BS_FRONTEND_IMAGE:-ghcr.io/blockscout/frontend:latest}"
export BS_VERIFIER_IMAGE="${BS_VERIFIER_IMAGE:-ghcr.io/blockscout/smart-contract-verifier:latest}"
export BS_STATS_IMAGE="${BS_STATS_IMAGE:-ghcr.io/blockscout/stats:latest}"
export BS_SECRET_KEY_BASE="${BS_SECRET_KEY_BASE:-mychain-l1-dev-please-change-in-prod-this-is-a-long-fixed-secret-string-for-testing-only}"
export BS_PORT BS_API_PORT BS_STATS_PORT
export BS_PUBLIC_HOST BS_PUBLIC_PROTOCOL BS_PUBLIC_PORT
export BS_PUBLIC_API_HOST BS_PUBLIC_API_PROTOCOL BS_PUBLIC_API_PORT
export BS_PUBLIC_BASE_URL BS_WS_PROTOCOL BS_RPC_URL
export BS_STATS_API_HOST BS_STATS_API_BASE_PATH

mkdir -p blockscout/envs
envsubst < blockscout/envs/backend.env.tpl  > blockscout/envs/backend.env
envsubst < blockscout/envs/frontend.env.tpl > blockscout/envs/frontend.env

echo "==> 已渲染 blockscout/envs/backend.env"
echo "==> 已渲染 blockscout/envs/frontend.env"

# -----------------------------------------------------------------------------
# 3) favicon 套件预生成（ImageMagick 一次性渲染 8 个尺寸）
#    脚本自带 "源图没变就跳过" 的检测，重复跑零成本
# -----------------------------------------------------------------------------
bash scripts/blockscout-make-favicon.sh

# -----------------------------------------------------------------------------
# 4) docker compose up
# -----------------------------------------------------------------------------
cd blockscout
docker compose --env-file ../.env up -d

cd ..
echo ""
echo "==> 等 backend 健康（首次启动会跑 DB 迁移，约 1-2 分钟）..."
for i in {1..60}; do
  STATUS="$(docker inspect --format '{{.State.Health.Status}}' mychain-l1-bs-backend 2>/dev/null || echo starting)"
  printf "\r    [%02d/60] backend=%s" "$i" "$STATUS"
  if [[ "$STATUS" == "healthy" ]]; then
    echo ""
    break
  fi
  sleep 5
done

echo ""
echo "✅ L1 Blockscout 启动完成"
echo ""
echo "  Frontend : http://${PUBLIC_HOST}:${BS_PORT}"
echo "  API      : http://${PUBLIC_HOST}:${BS_API_PORT}"
echo "  Stats    : http://${PUBLIC_HOST}:${BS_STATS_PORT}"
if [[ -n "${BS_PUBLIC_URL:-}" ]]; then
  echo ""
  echo "  反代域名 : $BS_PUBLIC_URL"
  echo "  Nginx 转发示例（贴到反代）:"
  echo "    location /api/    { proxy_pass http://127.0.0.1:${BS_API_PORT}/api/; }"
  echo "    location /socket/ {"
  echo "      proxy_pass http://127.0.0.1:${BS_API_PORT}/socket/;"
  echo "      proxy_http_version 1.1;"
  echo "      proxy_set_header Upgrade \$http_upgrade;"
  echo "      proxy_set_header Connection \"upgrade\";"
  echo "    }"
  echo "    location /stats-api/ { proxy_pass http://127.0.0.1:${BS_STATS_PORT}/; }"
  echo "    location /          { proxy_pass http://127.0.0.1:${BS_PORT}/; }"
fi
