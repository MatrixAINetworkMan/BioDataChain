#!/usr/bin/env bash
# =============================================================================
# Blockscout 独立部署 —— 一键安装 / 更新脚本
#
# 干的事：
#   1. 环境自检（docker / compose / envsubst / jq / curl）
#   2. 读 .env，校验必填项没留占位符
#   3. 连通性自检（能否访问远程 L2 RPC / L1 RPC，chainId 对不对）
#   4. 没有 SECRET_KEY_BASE 就自动生成并写回 .env
#   5. 计算前端要用的 BS_PUBLIC_* / BS_STATS_* 派生变量
#   6. 用 envsubst 渲染 envs/backend.env + envs/frontend.env
#   7. docker compose pull + up -d
#   8. 等 backend 健康，打印访问地址
#
# 幂等：可反复运行（改完 .env 再跑一次就重新渲染 + 滚动更新容器）。
#
# 用法：
#   cp .env.example .env && vim .env     # 填好 REPLACE_ME 的项
#   ./install.sh
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"

# 小工具：带颜色的日志
log()  { echo -e "==> $*"; }
ok()   { echo -e "    ✅ $*"; }
warn() { echo -e "    ⚠️  $*"; }
die()  { echo -e "    ❌ $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. 环境自检
# -----------------------------------------------------------------------------
log "1/8 检查本机依赖 ..."
command -v docker >/dev/null   || die "没装 docker"
docker compose version >/dev/null 2>&1 || die "没装 docker compose v2（docker compose version 失败）"
command -v envsubst >/dev/null || die "没装 envsubst（apt install gettext-base / apk add gettext）"
command -v jq >/dev/null       || die "没装 jq（apt install jq / apk add jq）"
command -v curl >/dev/null     || die "没装 curl"
ok "依赖齐全"

# -----------------------------------------------------------------------------
# 2. 读 .env
# -----------------------------------------------------------------------------
log "2/8 读取 .env ..."
[[ -f .env ]] || die "没有 .env，先 cp .env.example .env 再填好里面的值"
set -a; source .env; set +a

# 必填项校验：不能是空 / 占位符
check_filled() {
  local name="$1" val="${!1:-}"
  [[ -n "$val" ]]                  || die "$name 未设置"
  [[ "$val" != *REPLACE_ME* ]]     || die "$name 还是占位符，请填真实值"
}
for v in L2_RPC_HTTP L2_RPC_WS L2_RPC_TRACE L1_RPC L2_CHAIN_ID \
         NATIVE_TOKEN_SYMBOL NATIVE_TOKEN_NAME \
         OPTIMISM_PORTAL_PROXY SYSTEM_CONFIG_PROXY DISPUTE_GAME_FACTORY_PROXY \
         BATCHER_ADDRESS BATCH_INBOX_ADDRESS \
         BLOCKSCOUT_BACKEND_IMAGE BLOCKSCOUT_FRONTEND_IMAGE BLOCKSCOUT_STATS_IMAGE \
         BLOCKSCOUT_VERIFIER_IMAGE BLOCKSCOUT_SIG_PROVIDER_IMAGE \
         BLOCKSCOUT_PORT BLOCKSCOUT_API_PORT BLOCKSCOUT_STATS_PORT; do
  check_filled "$v"
done
ok ".env 必填项齐全"

# -----------------------------------------------------------------------------
# 3. 连通性自检
# -----------------------------------------------------------------------------
log "3/8 检查远程 RPC 连通性 ..."

rpc_call() {  # $1=url $2=method
  curl -s --max-time 8 -X POST "$1" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":[],\"id\":1}"
}

# L2 HTTP：chainId 必须跟 .env 的 L2_CHAIN_ID 对上
L2_CID_HEX=$(rpc_call "$L2_RPC_HTTP" eth_chainId | jq -r '.result // empty')
[[ -n "$L2_CID_HEX" ]] || die "L2_RPC_HTTP ($L2_RPC_HTTP) 不通或没返回 chainId"
L2_CID_DEC=$(( L2_CID_HEX ))
if [[ "$L2_CID_DEC" != "$L2_CHAIN_ID" ]]; then
  die "L2 chainId 不匹配：RPC 返回 $L2_CID_DEC，.env 写的 $L2_CHAIN_ID"
fi
ok "L2 RPC 通，chainId=$L2_CID_DEC"

# L2 trace：探测 debug 命名空间（debug_getRawHeader 不报 method not found 即可）
if rpc_call "$L2_RPC_TRACE" debug_getBadBlocks | grep -q '"result"'; then
  ok "L2 trace RPC debug 命名空间可用"
else
  warn "L2 trace RPC 的 debug 命名空间可能没开（internal txns 索引会缺）。op-geth 需 --http.api 含 debug"
fi

# L1：能拿到块高就行
L1_BN=$(rpc_call "$L1_RPC" eth_blockNumber | jq -r '.result // empty')
[[ -n "$L1_BN" ]] && ok "L1 RPC 通，块高 $(( L1_BN ))" || warn "L1_RPC ($L1_RPC) 不通，optimism 跨链索引会失败（deposit/withdrawal/batch）"

# WS 不好用 curl 测，只提示
warn "WS ($L2_RPC_WS) 未自动测试；实时索引依赖它，确保本机能连到该端口"

# -----------------------------------------------------------------------------
# 4. SECRET_KEY_BASE
# -----------------------------------------------------------------------------
log "4/8 检查 SECRET_KEY_BASE ..."
if [[ -z "${BLOCKSCOUT_SECRET_KEY_BASE:-}" ]]; then
  GEN=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p | tr -d '\n')
  # 写回 .env（替换空行或追加）
  if grep -q '^BLOCKSCOUT_SECRET_KEY_BASE=' .env; then
    sed -i.bak "s|^BLOCKSCOUT_SECRET_KEY_BASE=.*|BLOCKSCOUT_SECRET_KEY_BASE=${GEN}|" .env && rm -f .env.bak
  else
    echo "BLOCKSCOUT_SECRET_KEY_BASE=${GEN}" >> .env
  fi
  export BLOCKSCOUT_SECRET_KEY_BASE="$GEN"
  ok "已自动生成 SECRET_KEY_BASE 并写回 .env"
else
  ok "已有 SECRET_KEY_BASE"
fi

# -----------------------------------------------------------------------------
# 5. 计算 BS_PUBLIC_* / BS_STATS_* 派生变量（前端模板要用）
# -----------------------------------------------------------------------------
log "5/8 计算前端派生变量 ..."

# --- Blockscout 前端 / API 对外地址 ---
if [[ -n "${BLOCKSCOUT_PUBLIC_URL:-}" ]]; then
  # 反代模式：https://域名，frontend 与 API 同域（nginx 分流）
  _proto="${BLOCKSCOUT_PUBLIC_URL%%://*}"
  _rest="${BLOCKSCOUT_PUBLIC_URL#*://}"; _rest="${_rest%%/*}"
  if [[ "$_rest" == *:* ]]; then _host="${_rest%:*}"; _port="${_rest##*:}";
  else _host="$_rest"; [[ "$_proto" == https ]] && _port=443 || _port=80; fi
  BS_PUBLIC_PROTOCOL="$_proto"; BS_PUBLIC_HOST="$_host"; BS_PUBLIC_PORT="$_port"
  BS_PUBLIC_API_PROTOCOL="$_proto"; BS_PUBLIC_API_HOST="$_host"; BS_PUBLIC_API_PORT="$_port"
  [[ "$_proto" == https ]] && BS_WS_PROTOCOL=wss || BS_WS_PROTOCOL=ws
else
  # 直连模式：http://IP:端口
  BS_PUBLIC_PROTOCOL=http; BS_PUBLIC_HOST="$PUBLIC_HOST"; BS_PUBLIC_PORT="$BLOCKSCOUT_PORT"
  BS_PUBLIC_API_PROTOCOL=http; BS_PUBLIC_API_HOST="$PUBLIC_HOST"; BS_PUBLIC_API_PORT="$BLOCKSCOUT_API_PORT"
  BS_WS_PROTOCOL=ws
fi
case "${BS_PUBLIC_PROTOCOL}:${BS_PUBLIC_PORT}" in
  http:80|https:443) BS_PUBLIC_BASE_URL="${BS_PUBLIC_PROTOCOL}://${BS_PUBLIC_HOST}" ;;
  *)                 BS_PUBLIC_BASE_URL="${BS_PUBLIC_PROTOCOL}://${BS_PUBLIC_HOST}:${BS_PUBLIC_PORT}" ;;
esac

# --- stats 对外地址：拆成 origin + base_path（关键，否则前端丢前缀）---
if [[ -n "${BLOCKSCOUT_STATS_PUBLIC_URL:-}" ]]; then
  _sp="${BLOCKSCOUT_STATS_PUBLIC_URL%%://*}"
  _sr="${BLOCKSCOUT_STATS_PUBLIC_URL#*://}"
  if [[ "$_sr" == */* ]]; then _shp="${_sr%%/*}"; _spath="/${_sr#*/}"; _spath="${_spath%/}";
  else _shp="$_sr"; _spath=""; fi
  if [[ "$_shp" == *:* ]]; then _sh="${_shp%:*}"; _sport="${_shp##*:}";
  else _sh="$_shp"; [[ "$_sp" == https ]] && _sport=443 || _sport=80; fi
  case "${_sp}:${_sport}" in
    http:80|https:443) BS_STATS_ORIGIN="${_sp}://${_sh}" ;;
    *)                 BS_STATS_ORIGIN="${_sp}://${_sh}:${_sport}" ;;
  esac
  BS_STATS_BASE_PATH="${_spath:-/}"
else
  # 没配反代 → 直连本机 stats 端口
  BS_STATS_ORIGIN="http://${PUBLIC_HOST}:${BLOCKSCOUT_STATS_PORT}"
  BS_STATS_BASE_PATH="/"
fi

export BS_PUBLIC_PROTOCOL BS_PUBLIC_HOST BS_PUBLIC_PORT
export BS_PUBLIC_API_PROTOCOL BS_PUBLIC_API_HOST BS_PUBLIC_API_PORT
export BS_WS_PROTOCOL BS_PUBLIC_BASE_URL BS_STATS_ORIGIN BS_STATS_BASE_PATH
ok "对外地址：${BS_PUBLIC_BASE_URL}  | stats: ${BS_STATS_ORIGIN}${BS_STATS_BASE_PATH}"

# -----------------------------------------------------------------------------
# 6. 渲染 env 模板
# -----------------------------------------------------------------------------
log "6/8 渲染 envs/*.env ..."
mkdir -p envs
# envsubst 只替换白名单里的变量，避免误伤密钥里的 $
VARS='${L2_RPC_HTTP} ${L2_RPC_WS} ${L2_RPC_TRACE} ${L2_RPC_PUBLIC_URL} ${L1_RPC} ${L1_BLOCK_TIME}
${L2_CHAIN_ID} ${NATIVE_TOKEN_SYMBOL} ${NATIVE_TOKEN_NAME} ${BLOCKSCOUT_SECRET_KEY_BASE}
${OPTIMISM_PORTAL_PROXY} ${SYSTEM_CONFIG_PROXY} ${DISPUTE_GAME_FACTORY_PROXY}
${BATCHER_ADDRESS} ${BATCH_INBOX_ADDRESS} ${INDEXER_OPTIMISM_L2_BATCH_GENESIS_BLOCK_NUMBER}
${BS_PUBLIC_PROTOCOL} ${BS_PUBLIC_HOST} ${BS_PUBLIC_PORT}
${BS_PUBLIC_API_PROTOCOL} ${BS_PUBLIC_API_HOST} ${BS_PUBLIC_API_PORT}
${BS_WS_PROTOCOL} ${BS_PUBLIC_BASE_URL} ${BS_STATS_ORIGIN} ${BS_STATS_BASE_PATH}'
: "${INDEXER_OPTIMISM_L2_BATCH_GENESIS_BLOCK_NUMBER:=0}"; export INDEXER_OPTIMISM_L2_BATCH_GENESIS_BLOCK_NUMBER
envsubst "$VARS" < envs/backend.env.tpl  > envs/backend.env
envsubst "$VARS" < envs/frontend.env.tpl > envs/frontend.env
ok "backend.env / frontend.env 渲染完毕"

# -----------------------------------------------------------------------------
# 6.5 assets 自检 + favicon 套件兜底生成
#
# docker-compose.yml 把 assets/ 下的 logo / icon / 9 个 favicon 文件 bind-mount
# 进 frontend 容器。host 这边缺任意一个 → docker 会自动 mkdir 同名空目录 →
# mount 一个 dir 到容器里本来是 file 的位置 → "not a directory" 启动失败。
# 所以在 docker compose up 之前必须把 assets 准备齐全。
# -----------------------------------------------------------------------------
log "6.5/8 检查 assets/ 并按需生成 favicon 套件 ..."

# logo.svg / icon.svg 是手放的"源"，缺了无法自动生成 → fail-fast
MISSING_SRC=()
[[ -f assets/logo.svg ]] || MISSING_SRC+=("assets/logo.svg")
[[ -f assets/icon.svg ]] || MISSING_SRC+=("assets/icon.svg")
if (( ${#MISSING_SRC[@]} > 0 )); then
  die "assets/ 缺源文件：${MISSING_SRC[*]}
       从链仓库拷过来即可：
         scp <链机器>:/path/to/mychain/dev/blockscout/assets/{logo.svg,icon.svg} ./assets/
       或者 git pull 后 standalone 仓库自带的 assets/ 也行（推荐入库一份）"
fi

# 清掉 docker 上次启动失败留下的"伪 favicon 目录"（src 不存在时 docker 自动 mkdir）
for f in favicon.ico favicon-16x16.png favicon-32x32.png favicon-48x48.png \
         favicon-96x96.png apple-touch-icon-180x180.png \
         android-chrome-192x192.png android-chrome-512x512.png; do
  if [[ -d "assets/favicon/$f" ]]; then
    warn "清理 docker 上次失败留下的伪目录 assets/favicon/$f"
    rmdir "assets/favicon/$f" 2>/dev/null || rm -rf "assets/favicon/$f"
  fi
done

# favicon/ 套件缺就调本地脚本生成（脚本内部会判幂等：齐全且不旧就直接退出）
if [[ -x scripts/make-favicon.sh ]]; then
  bash scripts/make-favicon.sh || die "scripts/make-favicon.sh 失败（看上面错误）。
       常见原因：本机没装 docker / 拉不到 dpokidov/imagemagick 镜像 / assets/icon.svg 损坏"
  ok "assets/favicon/ 套件就绪"
else
  warn "scripts/make-favicon.sh 不存在或没执行权限，跳过 favicon 自动生成"
  warn "你需要手动准备齐 assets/favicon/ 下的 8 个文件，否则下一步 docker compose up 会炸"
fi

# -----------------------------------------------------------------------------
# 7. 拉镜像 + 起服务
# -----------------------------------------------------------------------------
log "7/8 拉镜像 + 启动 ..."
# --ignore-pull-failures：后端 optimism flavor 是本地自编译镜像（registry 里没有），
# 直接 pull 会失败并中断；远程的 frontend/stats/verifier/sig 仍会正常拉取。
docker compose --env-file .env pull --ignore-pull-failures
docker compose --env-file .env up -d

# -----------------------------------------------------------------------------
# 8. 等 backend 健康
# -----------------------------------------------------------------------------
log "8/8 等 backend 起来（首次要建表 + 索引创世，1-3 分钟）..."
for i in $(seq 1 60); do
  if curl -s --max-time 3 "http://127.0.0.1:${BLOCKSCOUT_API_PORT}/api/v2/blocks?limit=1" | grep -q '"items"'; then
    ok "backend 健康"
    break
  fi
  sleep 5
  [[ $i -eq 60 ]] && warn "backend 还没就绪，自己看日志：docker compose logs -f backend"
done

echo ""
echo "========================================================================="
echo "✅ Blockscout 独立部署完成"
echo ""
echo "  前端          ${BS_PUBLIC_BASE_URL}"
echo "  API           ${BS_PUBLIC_BASE_URL}/api/v2/blocks?limit=1"
echo "  stats         ${BS_STATS_ORIGIN}${BS_STATS_BASE_PATH}/api/v1/pages/main"
echo "  本机端口      frontend:${BLOCKSCOUT_PORT}  api:${BLOCKSCOUT_API_PORT}  stats:${BLOCKSCOUT_STATS_PORT}"
echo ""
echo "  下一步：配置 nginx（见 nginx/blockscout.conf.example）把域名反代到上面端口"
echo "  日志：docker compose logs -f backend"
echo "========================================================================="
