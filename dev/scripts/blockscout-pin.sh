#!/usr/bin/env bash
# 把当前正在跑的 Blockscout 镜像 pin 到 .env（用 RepoDigest sha256，比 tag 更精确）
#
# 起因：Blockscout 5 个镜像（backend/frontend/stats/verifier/sig-provider）
# 默认都用 :latest，不同时间 docker pull 拉到的版本不一致，会导致 frontend
# 调用 stats 的 API 端点 404、协议错配等问题。
#
# 用法：
#   make blockscout-pin              # 显示当前 digest，并把 5 行写入 .env
#   make blockscout-pin SHOW=1       # 只显示当前 digest，不动 .env（dry-run）
#
# 升级 Blockscout 流程：
#   1. 编辑 .env，临时把 5 行 BLOCKSCOUT_*_IMAGE 改回 :latest（或 :某新 tag）
#   2. make blockscout-down && make blockscout-up   # 拉新版起新容器
#   3. 验证浏览器一切正常
#   4. make blockscout-pin                          # 把新 digest pin 回 .env
set -euo pipefail

cd "$(dirname "$0")/.."

declare -A SVC_TO_VAR=(
  [mychain-blockscout-backend]=BLOCKSCOUT_BACKEND_IMAGE
  [mychain-blockscout-frontend]=BLOCKSCOUT_FRONTEND_IMAGE
  [mychain-blockscout-stats]=BLOCKSCOUT_STATS_IMAGE
  [mychain-blockscout-verifier]=BLOCKSCOUT_VERIFIER_IMAGE
  [mychain-blockscout-sig-provider]=BLOCKSCOUT_SIG_PROVIDER_IMAGE
)

# 固定顺序输出，保持每次 .env 写入顺序一致（方便 diff）
ORDER=(
  mychain-blockscout-backend
  mychain-blockscout-frontend
  mychain-blockscout-stats
  mychain-blockscout-verifier
  mychain-blockscout-sig-provider
)

PIN_LINES=()
VER_INFO=()
FAIL=0
for svc in "${ORDER[@]}"; do
  var=${SVC_TO_VAR[$svc]}
  img_id=$(docker inspect "$svc" -f '{{.Image}}' 2>/dev/null || true)
  if [[ -z "$img_id" ]]; then
    echo "❌ $svc 容器不存在，先 make blockscout-up" >&2
    FAIL=1
    continue
  fi
  digest=$(docker inspect "$img_id" -f '{{range .RepoDigests}}{{.}}{{"\n"}}{{end}}' 2>/dev/null | head -1)
  ver=$(docker inspect "$img_id" -f '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)
  if [[ -z "$digest" ]]; then
    echo "❌ $svc 镜像没有 RepoDigest（可能是本地 build？），无法 pin" >&2
    FAIL=1
    continue
  fi
  PIN_LINES+=("$var=$digest")
  VER_INFO+=("$var=$ver")
done

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi

echo "==> 当前 Blockscout 镜像版本:"
for line in "${VER_INFO[@]}"; do echo "    $line"; done
echo ""
echo "==> 待 pin 的 digest 行:"
for line in "${PIN_LINES[@]}"; do echo "    $line"; done

if [[ "${SHOW:-}" == "1" ]]; then
  echo ""
  echo "(SHOW=1，未修改 .env)"
  exit 0
fi

if [[ ! -f .env ]]; then
  echo "❌ 没找到 dev/.env" >&2
  exit 1
fi

BAK=".env.bak.$(date +%s)"
cp .env "$BAK"
echo ""
echo "==> 已备份 .env → $BAK"

# 删除原有 pin 行（不管是 :latest 还是 digest 还是别的 tag）
sed -i.tmp -E '/^BLOCKSCOUT_(BACKEND|FRONTEND|STATS|VERIFIER|SIG_PROVIDER)_IMAGE=/d' .env
rm -f .env.tmp

# 删可能存在的旧 pin 块注释（用同一个 marker 做幂等）
sed -i.tmp -E '/^# === BLOCKSCOUT_PIN_BLOCK_BEGIN ===$/,/^# === BLOCKSCOUT_PIN_BLOCK_END ===$/d' .env
rm -f .env.tmp

{
  echo ""
  echo "# === BLOCKSCOUT_PIN_BLOCK_BEGIN ==="
  echo "# Pinned at $(date '+%Y-%m-%d %H:%M:%S %Z') by scripts/blockscout-pin.sh"
  for line in "${VER_INFO[@]}"; do echo "# $line"; done
  echo "# 重新 pin: make blockscout-pin   |   查看不写: make blockscout-pin SHOW=1"
  for line in "${PIN_LINES[@]}"; do echo "$line"; done
  echo "# === BLOCKSCOUT_PIN_BLOCK_END ==="
} >> .env

echo ""
echo "==> .env 写入完成。当前 pin:"
grep '^BLOCKSCOUT_.*_IMAGE' .env | sed 's/^/    /'
echo ""
echo "==> 验证 docker-compose 解析后的 image 字段:"
set -a; source .env; set +a
docker compose --env-file .env -f blockscout/docker-compose.yml config 2>/dev/null \
  | grep -E '^\s+image:.*@sha256:' | sort -u | sed 's/^/    /' || true
echo ""
echo "✅ 完成。下次 make blockscout-up 会严格按 digest 拉，不会被 :latest 偷换"
