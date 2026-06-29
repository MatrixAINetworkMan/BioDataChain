#!/usr/bin/env bash
# =============================================================================
# flashblocks-debug.sh — 一键诊断 v7 stack 部署失败原因
#
# 跑法：bash dev/scripts/flashblocks-debug.sh
# 用途：smoke 报 4 容器 missing 时第一步跑这个，定位卡在哪
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."

set -a
[[ -f .env ]] && source .env
[[ -f .env.flashblocks ]] && source .env.flashblocks
set +a

echo "============================================"
echo "🔍 v7 Flashblocks 部署诊断"
echo "============================================"

# ============= 1. host 基础环境 =============
echo ""
echo "1) host 基础环境"
echo "  docker     : $(docker --version 2>&1 | head -1)"
echo "  compose    : $(docker compose version 2>&1 | head -1)"
echo "  L2_CHAIN_ID: ${L2_CHAIN_ID:-未设}"
echo "  PUBLIC_HOST: ${PUBLIC_HOST:-未设}"
echo "  pwd        : $(pwd)"
echo "  files      : "
ls -1 .env .env.flashblocks docker-compose.yml docker-compose.flashblocks.yml 2>&1 | sed 's/^/    /'

# ============= 2. v6 主链容器 =============
echo ""
echo "2) v6 主链容器（必须先 healthy 才能起 v7）"
for c in mychain-anvil mychain-op-geth mychain-op-node mychain-op-batcher; do
  st=$(docker inspect -f '{{.State.Status}}/{{.State.Health.Status}}' "$c" 2>/dev/null) || st="missing"
  printf "  %-25s : %s\n" "$c" "$st"
done

# ============= 3. v7 image pull 状态 =============
echo ""
echo "3) v7 上游 image 是否在 host"
for img in "${OP_RBUILDER_IMAGE:-?}" "${ROLLUP_BOOST_IMAGE:-?}" "${FLASHBLOCKS_RPC_IMAGE:-?}"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    sz=$(docker image inspect "$img" --format '{{.Size}}' | awk '{printf "%.1f MB", $1/1024/1024}')
    echo "  ✅ $img ($sz)"
  else
    echo "  ❌ $img  ← 没拉到，下面试 pull 看错误"
  fi
done

echo ""
echo "  bundle-proxy 本地 build image："
if docker image inspect mychain/bundle-proxy:0.1.0 >/dev/null 2>&1; then
  sz=$(docker image inspect mychain/bundle-proxy:0.1.0 --format '{{.Size}}' | awk '{printf "%.1f MB", $1/1024/1024}')
  echo "  ✅ mychain/bundle-proxy:0.1.0 ($sz)"
else
  echo "  ❌ mychain/bundle-proxy:0.1.0 没 build  ← 跑 make flashblocks-build"
fi

# ============= 4. v7 容器存在状态 =============
echo ""
echo "4) v7 容器状态"
for c in mychain-op-rbuilder mychain-rollup-boost mychain-flashblocks-rpc mychain-bundle-proxy; do
  if docker inspect "$c" >/dev/null 2>&1; then
    st=$(docker inspect -f '{{.State.Status}} (exit={{.State.ExitCode}})' "$c" 2>/dev/null)
    printf "  %-30s : %s\n" "$c" "$st"
  else
    printf "  %-30s : %s\n" "$c" "missing（容器从未被创建）"
  fi
done

# ============= 5. compose config 解析 =============
echo ""
echo "5) docker-compose 配置解析（验证 yaml + env 正确）"
COMPOSE_OUT=$(docker compose --env-file .env --env-file .env.flashblocks \
  -f docker-compose.yml -f docker-compose.flashblocks.yml \
  config --services 2>&1)
echo "$COMPOSE_OUT" | head -15 | sed 's/^/  /'
if echo "$COMPOSE_OUT" | grep -q "bundle-proxy"; then
  echo "  ✅ compose 解析 OK，8 个 service 全在"
else
  echo "  ❌ compose 解析失败，看上面错误"
fi

# ============= 6. 试 pull 缺失 image（看具体错误）=============
echo ""
echo "6) 检查 image pull 错误"
for img in "${OP_RBUILDER_IMAGE:-x}" "${ROLLUP_BOOST_IMAGE:-x}" "${FLASHBLOCKS_RPC_IMAGE:-x}"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "  尝试 pull $img ..."
    docker pull "$img" 2>&1 | tail -3 | sed 's/^/    /' || true
  fi
done

# ============= 7. 端口占用 =============
echo ""
echo "7) host 端口占用检查（v6 + v7 一起看）"

# 端口冲突探测函数：看 ss / lsof / docker 三个来源
who_owns_port() {
  local port=$1
  # docker 容器
  local dc=$(docker ps -a --format "{{.Names}}|{{.Ports}}" 2>/dev/null | grep -E "[:0-9]${port}->|^[^|]*\|${port}/" | head -1)
  [[ -n "$dc" ]] && { echo "docker:$dc"; return; }
  # 系统进程（root 跑或 sudo）
  local ssout=$(ss -ltnp 2>/dev/null | grep ":${port} " | head -1)
  [[ -n "$ssout" ]] && { echo "host:$ssout"; return; }
  echo ""
}

# v6 关键端口（这些被占住 → make dev-up 头一步就 fail）
for entry in "8545=anvil(L1 RPC)" "${L2_RPC_PORT:-9545}=op-geth(L2 RPC)" "${L2_WS_PORT:-9546}=op-geth(L2 WS)" "8551=op-geth(engine API, 容器内, host 不暴露)" "30303=op-geth(P2P)"; do
  port="${entry%=*}"
  label="${entry#*=}"
  owner=$(who_owns_port "$port")
  if [[ -n "$owner" ]]; then
    echo "  ⚠️  $port ($label) 被占用：$owner"
  else
    echo "  ✅ $port ($label) 空闲"
  fi
done

# v7 端口
for port in "${OP_RBUILDER_PORT:-9550}" "${ROLLUP_BOOST_PORT:-9555}" "${FLASHBLOCKS_RPC_PORT:-9548}" "${BUNDLE_PROXY_PORT:-9560}" "${BUNDLE_PROXY_METRICS_PORT:-9561}"; do
  owner=$(who_owns_port "$port")
  if [[ -n "$owner" ]]; then
    echo "  ⚠️  $port (v7) 被占用：$owner"
  else
    echo "  ✅ $port (v7) 空闲"
  fi
done

# 看有没有 v6/v7 之外的容器残留（比如之前的 builder-playground 实验）
echo ""
echo "  非 mychain-* 但绑 ${L2_RPC_PORT:-9545}/8545/9550/9560 的容器："
docker ps -a --format "{{.Names}}\t{{.Ports}}\t{{.Status}}" 2>/dev/null | \
  grep -vE "^mychain-" | grep -E ":8545|:${L2_RPC_PORT:-9545}|:9550|:9560|:9555|:9548" | head -5 | sed 's/^/    /'
echo ""
echo "  如发现非 mychain-* 残留：docker stop <name> && docker rm <name>"

# ============= 8. workdir/shared 准备好（rbuilder 需要 jwt + genesis）=============
echo ""
echo "8) workdir/shared 关键文件（op-rbuilder/rollup-boost 都要的）"
for f in jwt.txt genesis.json rollup.json l1-chain-config.json; do
  if [[ -f "workdir/shared/$f" ]]; then
    sz=$(stat -c%s "workdir/shared/$f" 2>/dev/null || stat -f%z "workdir/shared/$f" 2>/dev/null)
    echo "  ✅ workdir/shared/$f ($sz bytes)"
  else
    echo "  ❌ workdir/shared/$f 缺失  ← 先 make dev-up 让 op-deployer 生成"
  fi
done

# ============= 9. 如果有 v7 容器存在但 crash，dump 日志 =============
echo ""
echo "9) v7 容器最近日志（如果存在）"
for c in mychain-op-rbuilder mychain-rollup-boost mychain-flashblocks-rpc mychain-bundle-proxy; do
  if docker inspect "$c" >/dev/null 2>&1; then
    echo ""
    echo "  --- $c 最后 20 行 ---"
    docker logs --tail 20 "$c" 2>&1 | sed 's/^/    /'
  fi
done

# ============= 10. 总结：最可能的根因 =============
echo ""
echo "============================================"
echo "🎯 诊断结论"
echo "============================================"

PROBLEM=""

PROBLEM=""
NEXT_ACTION=""

# 优先看端口冲突（这是最常见的部署 fail 根因）
if [[ -n "$(who_owns_port 8545)" ]] && ! docker inspect mychain-anvil >/dev/null 2>&1; then
  PROBLEM="host 8545 被别的进程占用（不是 mychain-anvil），anvil 起不来"
  NEXT_ACTION="找出占用者并停掉：
    sudo lsof -nP -iTCP:8545 -sTCP:LISTEN     # host 进程
    docker ps -a | grep 8545                  # docker 容器
  如果是之前 builder-playground 残留，常见在这俩 image：
    docker ps -a --format '{{.Names}}\t{{.Image}}' | grep -iE 'rbuilder|playground|geth|reth|anvil'
  全停掉：
    docker ps -a --format '{{.Names}}' | grep -v '^mychain-' | xargs -r docker stop
  然后：make dev-up-flashblocks"
elif ! docker inspect mychain-op-geth >/dev/null 2>&1; then
  PROBLEM="v6 主链没起"
  NEXT_ACTION="make dev-up（先把 v6 跑起来），再 make flashblocks-up"
elif [[ "$(docker inspect -f '{{.State.Health.Status}}' mychain-op-geth 2>/dev/null)" != "healthy" ]]; then
  PROBLEM="op-geth 不 healthy"
  NEXT_ACTION="make logs-op-geth | tail -50"
elif [[ ! -f workdir/shared/jwt.txt ]]; then
  PROBLEM="workdir/shared 没准备好"
  NEXT_ACTION="make dev-up 没跑完 deploy-genesis → 重跑 make dev-up，看 op-deployer 输出"
elif ! docker image inspect "${OP_RBUILDER_IMAGE:-x}" >/dev/null 2>&1 || \
     ! docker image inspect "${ROLLUP_BOOST_IMAGE:-x}" >/dev/null 2>&1; then
  PROBLEM="v7 上游 image 没拉到（${OP_RBUILDER_IMAGE}, ${ROLLUP_BOOST_IMAGE}）"
  NEXT_ACTION="docker pull ${OP_RBUILDER_IMAGE} && docker pull ${ROLLUP_BOOST_IMAGE}
  注意首次拉 ~300MB，别中途 Ctrl+C。
  如果 'manifest unknown'：tag 不存在。flashbots 的 ghcr image 用 git-sha tag
  （e.g. sha-e5e6711），不用 semver。到 pkgs 页查最新 tag：
    https://github.com/flashbots/op-rbuilder/pkgs/container/op-rbuilder
    https://github.com/flashbots/rollup-boost/pkgs/container/rollup-boost
  改 .env.flashblocks 的 OP_RBUILDER_IMAGE / ROLLUP_BOOST_IMAGE 重跑。"
elif ! docker image inspect mychain/bundle-proxy:0.1.0 >/dev/null 2>&1; then
  PROBLEM="bundle-proxy 本地没 build"
  NEXT_ACTION="make flashblocks-build"
elif ! docker inspect mychain-op-rbuilder >/dev/null 2>&1; then
  PROBLEM="v7 容器从未被创建"
  NEXT_ACTION="make flashblocks-up（如果失败把输出贴出来）"
else
  PROBLEM="v7 容器存在但 crash"
  NEXT_ACTION="看上面 §9 dump 的日志"
fi

echo ""
echo "  ❗ $PROBLEM"
echo ""
echo "下一步建议："
echo "$NEXT_ACTION" | sed 's/^/  /'
echo ""
echo "  完整输出贴回 AI 帮你下一轮诊断。"
