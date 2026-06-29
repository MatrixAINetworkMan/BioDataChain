#!/usr/bin/env bash
# 拉起 Blockscout（独立 stack，挂在主链 mychain-dev 网络上）
set -euo pipefail

cd "$(dirname "$0")/.."

# -----------------------------------------------------------------------------
# 0. 加载主链 .env 和 L1 合约地址
# -----------------------------------------------------------------------------
if [[ ! -f .env ]]; then
  echo "❌ 没找到 dev/.env，先 cp .env.example .env" >&2
  exit 1
fi

set -a
source .env
# v7 Flashblocks 覆盖：如果存在 .env.flashblocks，叠加 source。这一步把
# BLOCKSCOUT_INDEXER_RPC=http://flashblocks-rpc:8545 注入 envsubst 的环境，
# 让 backend.env.tpl 渲染时把 indexer 指向 flashblocks-rpc 而不是 op-geth。
# .env.flashblocks 不存在时这里跳过，Blockscout 仍按 v6 行为指向 op-geth。
if [[ -f .env.flashblocks ]]; then
  echo "==> 检测到 .env.flashblocks，叠加加载（v7 Flashblocks 模式）"
  source .env.flashblocks
fi
if [[ -f workdir/shared/l1-addresses.env ]]; then
  source workdir/shared/l1-addresses.env
else
  echo "❌ 没找到 workdir/shared/l1-addresses.env，主链可能还没部署" >&2
  echo "   先 make dev-up 把主链跑起来" >&2
  exit 1
fi
set +a

# Blockscout indexer RPC 默认值（envsubst 不支持 :- 语法，必须在 shell 里 default）
# 详见 docs/PHASE2_INTEGRATION.md §6.2
: "${BLOCKSCOUT_INDEXER_RPC:=http://op-geth:8545}"
: "${BLOCKSCOUT_INDEXER_TRACE_RPC:=http://op-geth:8545}"
: "${BLOCKSCOUT_INDEXER_WS:=ws://op-geth:8546}"
export BLOCKSCOUT_INDEXER_RPC BLOCKSCOUT_INDEXER_TRACE_RPC BLOCKSCOUT_INDEXER_WS

: "${PUBLIC_HOST:?PUBLIC_HOST 未在 .env 里设置（如 18.123.45.67）}"
: "${L2_CHAIN_ID:?}"
: "${L2_RPC_PORT:?}"
: "${ANVIL_PORT:?}"
: "${L1_BLOCK_TIME:?}"
: "${BLOCKSCOUT_PORT:?}"
: "${BLOCKSCOUT_API_PORT:?BLOCKSCOUT_API_PORT 未在 .env 里设置（默认 4001）}"
: "${BLOCKSCOUT_BACKEND_IMAGE:?}"
: "${BLOCKSCOUT_FRONTEND_IMAGE:?}"
: "${BLOCKSCOUT_VERIFIER_IMAGE:?}"
: "${BLOCKSCOUT_SIG_PROVIDER_IMAGE:?}"
: "${BLOCKSCOUT_SECRET_KEY_BASE:?BLOCKSCOUT_SECRET_KEY_BASE 未在 .env 里设置}"

# stats 微服务的两个 env 后加的，老的 .env 里没有 → 用默认值并 export，让下游
# envsubst / docker-compose 能拿到。想覆盖的人在 .env 显式设就行。
: "${BLOCKSCOUT_STATS_PORT:=4002}"
: "${BLOCKSCOUT_STATS_IMAGE:=ghcr.io/blockscout/stats:latest}"
export BLOCKSCOUT_STATS_PORT BLOCKSCOUT_STATS_IMAGE
: "${NATIVE_TOKEN_SYMBOL:?}"
: "${NATIVE_TOKEN_NAME:?}"
: "${OPTIMISM_PORTAL_PROXY:?l1-addresses.env 缺 OPTIMISM_PORTAL_PROXY，重跑 deploy-l1}"
: "${SYSTEM_CONFIG_PROXY:?}"
: "${DISPUTE_GAME_FACTORY_PROXY:?}"
: "${BATCHER_ADDRESS:?}"

# 从 rollup.json 取真实 batch_inbox_address（op-deployer 算的，比硬编码靠谱）
if [[ ! -f workdir/shared/rollup.json ]]; then
  echo "❌ workdir/shared/rollup.json 不存在，先 make deploy-genesis" >&2
  exit 1
fi
BATCH_INBOX_ADDRESS="$(jq -r '.batch_inbox_address' workdir/shared/rollup.json)"
if [[ -z "$BATCH_INBOX_ADDRESS" || "$BATCH_INBOX_ADDRESS" == "null" ]]; then
  echo "❌ rollup.json 里没有 batch_inbox_address" >&2
  exit 1
fi
export BATCH_INBOX_ADDRESS

# -----------------------------------------------------------------------------
# 0.5 计算浏览器对外访问 Blockscout 用的 protocol/host/port
#     - BLOCKSCOUT_PUBLIC_URL 设了 → 反代模式（HTTPS + 域名 + nginx 前置）
#     - BLOCKSCOUT_PUBLIC_URL 没设 → 直连模式（HTTP + IP + 容器端口）
#
# 反代模式假设 nginx 把 /api、/socket、/sitemap.xml、/auth/* proxy 到 backend(4001)，
# 其他路径 proxy 到 frontend(4000)，所以前端和 API 共享同一个 host:port。
# -----------------------------------------------------------------------------
if [[ -n "${BLOCKSCOUT_PUBLIC_URL:-}" ]]; then
  _bs_proto="${BLOCKSCOUT_PUBLIC_URL%%://*}"
  _bs_rest="${BLOCKSCOUT_PUBLIC_URL#*://}"
  _bs_rest="${_bs_rest%%/*}"
  if [[ "$_bs_rest" == *:* ]]; then
    _bs_host="${_bs_rest%:*}"
    _bs_port="${_bs_rest##*:}"
  else
    _bs_host="$_bs_rest"
    if [[ "$_bs_proto" == "https" ]]; then _bs_port=443; else _bs_port=80; fi
  fi
  BS_PUBLIC_PROTOCOL="$_bs_proto"
  BS_PUBLIC_HOST="$_bs_host"
  BS_PUBLIC_PORT="$_bs_port"
  BS_PUBLIC_API_PROTOCOL="$_bs_proto"
  BS_PUBLIC_API_HOST="$_bs_host"
  BS_PUBLIC_API_PORT="$_bs_port"
  if [[ "$_bs_proto" == "https" ]]; then BS_WS_PROTOCOL=wss; else BS_WS_PROTOCOL=ws; fi
  echo "==> 反代模式：浏览器走 ${BLOCKSCOUT_PUBLIC_URL} （nginx 前置，frontend+API 同域）"
else
  BS_PUBLIC_PROTOCOL=http
  BS_PUBLIC_HOST="$PUBLIC_HOST"
  BS_PUBLIC_PORT="$BLOCKSCOUT_PORT"
  BS_PUBLIC_API_PROTOCOL=http
  BS_PUBLIC_API_HOST="$PUBLIC_HOST"
  BS_PUBLIC_API_PORT="$BLOCKSCOUT_API_PORT"
  BS_WS_PROTOCOL=ws
  echo "==> 直连模式：浏览器走 http://${PUBLIC_HOST}:${BLOCKSCOUT_PORT}"
fi

# Asset / withdrawal 用的 base URL：标准端口（80/443）省略 :port 让 URL 干净
case "${BS_PUBLIC_PROTOCOL}:${BS_PUBLIC_PORT}" in
  http:80|https:443) BS_PUBLIC_BASE_URL="${BS_PUBLIC_PROTOCOL}://${BS_PUBLIC_HOST}" ;;
  *)                 BS_PUBLIC_BASE_URL="${BS_PUBLIC_PROTOCOL}://${BS_PUBLIC_HOST}:${BS_PUBLIC_PORT}" ;;
esac

# stats 微服务的浏览器对外入口（支持 3 种）：
#   1. 子域名反代:  https://stats.example.com
#   2. 路径反代:    https://demo.example.com/stats-api  ← 推荐（不用加 DNS/证书）
#   3. 直连:        留空，自动算成 http://${PUBLIC_HOST}:${BLOCKSCOUT_STATS_PORT}
#
# 注意：HTTPS 页面调 HTTP stats 会被浏览器 Mixed Content 阻断，所以反代模式
# 必须给 stats 也配 HTTPS（要么独立子域名，要么走主站 path）
if [[ -n "${BLOCKSCOUT_STATS_PUBLIC_URL:-}" ]]; then
  _stats_proto="${BLOCKSCOUT_STATS_PUBLIC_URL%%://*}"
  _stats_after_proto="${BLOCKSCOUT_STATS_PUBLIC_URL#*://}"
  # 拆成 hostport + path
  if [[ "$_stats_after_proto" == */* ]]; then
    _stats_hostport="${_stats_after_proto%%/*}"
    _stats_path="/${_stats_after_proto#*/}"
    _stats_path="${_stats_path%/}"   # 去掉末尾 / 让拼接干净
  else
    _stats_hostport="$_stats_after_proto"
    _stats_path=""
  fi
  if [[ "$_stats_hostport" == *:* ]]; then
    BS_STATS_HOST="${_stats_hostport%:*}"
    BS_STATS_PORT="${_stats_hostport##*:}"
  else
    BS_STATS_HOST="$_stats_hostport"
    if [[ "$_stats_proto" == "https" ]]; then BS_STATS_PORT=443; else BS_STATS_PORT=80; fi
  fi
  BS_STATS_PROTOCOL="$_stats_proto"
  BS_STATS_PATH="$_stats_path"
  echo "==> stats 反代模式：浏览器走 ${BLOCKSCOUT_STATS_PUBLIC_URL}"
else
  BS_STATS_PROTOCOL=http
  BS_STATS_HOST="$PUBLIC_HOST"
  BS_STATS_PORT="$BLOCKSCOUT_STATS_PORT"
  BS_STATS_PATH=""
  echo "==> stats 直连模式：浏览器走 http://${PUBLIC_HOST}:${BLOCKSCOUT_STATS_PORT}"
  echo "    ⚠️  如果 Blockscout 主站走 HTTPS，浏览器会因 Mixed Content 拦截 stats 请求"
  echo "       建议在 .env 里设 BLOCKSCOUT_STATS_PUBLIC_URL=https://<主站>/stats-api"
fi

case "${BS_STATS_PROTOCOL}:${BS_STATS_PORT}" in
  http:80|https:443) BS_STATS_BASE_URL="${BS_STATS_PROTOCOL}://${BS_STATS_HOST}${BS_STATS_PATH}" ;;
  *)                 BS_STATS_BASE_URL="${BS_STATS_PROTOCOL}://${BS_STATS_HOST}:${BS_STATS_PORT}${BS_STATS_PATH}" ;;
esac

# 前端拼 stats 请求 URL 的方式是 new URL(resourcePath, HOST)，而 stats 的
# resourcePath 是写死的绝对路径 /api/v1/...。如果把 path 前缀塞进 HOST
# （如 https://host/stats-api），绝对路径会覆盖掉前缀导致前缀丢失 → 打到 backend 400。
# 正确做法（见官方 ENVS）：HOST 只给 origin，路径前缀单独通过
# NEXT_PUBLIC_STATS_API_BASE_PATH 传（例 /poa/core）。下面拆出 origin + base_path。
case "${BS_STATS_PROTOCOL}:${BS_STATS_PORT}" in
  http:80|https:443) BS_STATS_ORIGIN="${BS_STATS_PROTOCOL}://${BS_STATS_HOST}" ;;
  *)                 BS_STATS_ORIGIN="${BS_STATS_PROTOCOL}://${BS_STATS_HOST}:${BS_STATS_PORT}" ;;
esac
BS_STATS_BASE_PATH="${BS_STATS_PATH:-/}"

export BS_PUBLIC_PROTOCOL BS_PUBLIC_HOST BS_PUBLIC_PORT
export BS_PUBLIC_API_PROTOCOL BS_PUBLIC_API_HOST BS_PUBLIC_API_PORT
export BS_WS_PROTOCOL BS_PUBLIC_BASE_URL
export BS_STATS_PROTOCOL BS_STATS_HOST BS_STATS_PORT BS_STATS_PATH BS_STATS_BASE_URL
export BS_STATS_ORIGIN BS_STATS_BASE_PATH

# -----------------------------------------------------------------------------
# 1. 检查主链 docker 网络是否存在
# -----------------------------------------------------------------------------
if ! docker network inspect mychain-dev >/dev/null 2>&1; then
  echo "❌ docker network mychain-dev 不存在，主链没起来" >&2
  echo "   先 make dev-up 把主链跑起来" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q '^mychain-op-geth$'; then
  echo "⚠️  mychain-op-geth 容器不在运行，blockscout 起来后也会报 RPC 失败"
  echo "   建议先 make status 确认主链健康"
fi

# -----------------------------------------------------------------------------
# 1.4 favicon 套件预生成
#     Blockscout entrypoint 在反代模式下自己 fetch 自己拿不到 icon.svg，favicon
#     生成必然失败 → 浏览器 tab 永远是默认/空 logo。这里在 docker compose up 之前
#     用 ImageMagick 把全套 favicon 渲染好，docker-compose 的 mount 把它们挂进容器
#     /app/public/，绕过 entrypoint 的下载-生成路径。
#
#     脚本自带"icon.svg 没变就跳过"的检测，重复跑零成本。
# -----------------------------------------------------------------------------
bash scripts/blockscout-make-favicon.sh

# -----------------------------------------------------------------------------
# 1.5 链指纹检测：比对 chain_id + L2 genesis hash，链一旦重建就强制 wipe DB
#
# 为什么必须 wipe：
#   make dev-clean 只清主链 volume，但 Blockscout 的 postgres 卷不归它管，
#   所以 dev-clean → dev-up → blockscout-up 之后，旧链的块还堆在 DB 里，
#   indexer 跟新链对不上，前端会一直显示旧块、新交易又索引不出来。
#
# 指纹来源：${L2_CHAIN_ID}（来自 .env）+ rollup.json 的 .genesis.l2.hash
#   - chain_id 改了显然必须 wipe
#   - 即使 chain_id 不变，dev-clean 之后 anvil genesis_timestamp 重写，
#     L2 创世时间也变 → genesis hash 变 → 也必须 wipe
#
# genesis.l2.hash 是 03-init-geth.sh 跑完后 patch 进 rollup.json 的真实块 0 哈希，
# op-node 跟 op-geth 都靠这个对齐，拿来当指纹最稳。
# -----------------------------------------------------------------------------
GENESIS_HASH="$(jq -r '.genesis.l2.hash // empty' workdir/shared/rollup.json)"
if [[ -z "$GENESIS_HASH" || "$GENESIS_HASH" != 0x* ]]; then
  echo "❌ 无法从 rollup.json 读 .genesis.l2.hash（'$GENESIS_HASH'），先 make init-geth" >&2
  exit 1
fi
FP_CURRENT="${L2_CHAIN_ID}:${GENESIS_HASH}"

FP_FILE="blockscout/.chain-fingerprint"
NEEDS_CLEAN=0
if [[ -f "$FP_FILE" ]]; then
  FP_PREV="$(cat "$FP_FILE")"
  if [[ "$FP_PREV" != "$FP_CURRENT" ]]; then
    NEEDS_CLEAN=1
    echo ""
    echo "⚠️  检测到链已重建（指纹变了）"
    echo "    旧: $FP_PREV"
    echo "    新: $FP_CURRENT"
    echo "    将自动 wipe Blockscout 的 postgres + redis volume，重新索引整条链"
    echo ""
  fi
fi

# 即使指纹没变，如果 postgres 容器不存在但 volume 还在（之前异常 down 过），
# blockscout-up 起来时 backend 也可能因迁移半途中断而炸；这里不主动处理，
# 只在指纹不一致时才 wipe，把"诡异问题"留给 make blockscout-clean 手动兜底。

if [[ "$NEEDS_CLEAN" == "1" ]]; then
  echo "==> 拆掉旧 stack + volume ..."
  docker compose -f blockscout/docker-compose.yml --env-file .env down -v --remove-orphans 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# 2. 渲染 envs/*.env.tpl -> envs/*.env
# -----------------------------------------------------------------------------
echo "==> 渲染 blockscout/envs/*.env ..."
mkdir -p blockscout/envs

# envsubst 需要明确告诉它要替换哪些变量，否则它会试图替换 ${VAR} 之外的所有 $XXX
# （Elixir/Phoenix env 文件里 $ 字符可能出现在密钥里）
TEMPLATE_VARS='${PUBLIC_HOST} ${L2_CHAIN_ID} ${L2_RPC_PORT} ${ANVIL_PORT} ${L1_BLOCK_TIME}
${BLOCKSCOUT_PORT} ${BLOCKSCOUT_API_PORT} ${BLOCKSCOUT_STATS_PORT} ${BLOCKSCOUT_SECRET_KEY_BASE}
${NATIVE_TOKEN_SYMBOL} ${NATIVE_TOKEN_NAME}
${OPTIMISM_PORTAL_PROXY} ${SYSTEM_CONFIG_PROXY} ${DISPUTE_GAME_FACTORY_PROXY}
${BATCHER_ADDRESS} ${BATCH_INBOX_ADDRESS}
${BS_PUBLIC_PROTOCOL} ${BS_PUBLIC_HOST} ${BS_PUBLIC_PORT}
${BS_PUBLIC_API_PROTOCOL} ${BS_PUBLIC_API_HOST} ${BS_PUBLIC_API_PORT}
${BS_WS_PROTOCOL} ${BS_PUBLIC_BASE_URL}
${BS_STATS_PROTOCOL} ${BS_STATS_HOST} ${BS_STATS_PORT} ${BS_STATS_BASE_URL}
${BS_STATS_ORIGIN} ${BS_STATS_BASE_PATH}
${BLOCKSCOUT_INDEXER_RPC} ${BLOCKSCOUT_INDEXER_TRACE_RPC} ${BLOCKSCOUT_INDEXER_WS}'

envsubst "$TEMPLATE_VARS" < blockscout/envs/backend.env.tpl  > blockscout/envs/backend.env
envsubst "$TEMPLATE_VARS" < blockscout/envs/frontend.env.tpl > blockscout/envs/frontend.env

echo "    backend.env  / frontend.env 渲染完毕"

# -----------------------------------------------------------------------------
# 3. 拉起 stack
# -----------------------------------------------------------------------------
echo ""
echo "==> 拉起 Blockscout 8 个服务（首次启动 backend + stats 要做 DB migration，约 60-180 秒）..."
docker compose -f blockscout/docker-compose.yml --env-file .env up -d

# 记录本次部署时的链指纹，下次启动靠它判断"链是不是又重建了"
echo "$FP_CURRENT" > "$FP_FILE"

echo ""
echo "✅ Blockscout 已启动"
echo ""
echo "服务状态："
docker compose -f blockscout/docker-compose.yml --env-file .env ps
echo ""
echo "首次启动 backend 要建表 + 索引创世块，请等 1-2 分钟再访问"
echo ""
echo "  浏览器界面    ${BS_PUBLIC_BASE_URL}"
echo "  API           ${BS_PUBLIC_BASE_URL}/api/v2/blocks?limit=1"
echo "  Stats         ${BS_STATS_BASE_URL}/api/v1/lines"
if [[ -n "${BLOCKSCOUT_PUBLIC_URL:-}" ]]; then
echo "  （直连备用    http://${PUBLIC_HOST}:${BLOCKSCOUT_PORT} / :${BLOCKSCOUT_API_PORT} / :${BLOCKSCOUT_STATS_PORT}，绕过 nginx 调试用）"
fi
echo ""
echo "看后端日志（监控 indexing 进度）：make blockscout-logs"
