#!/usr/bin/env bash
# 等某个 docker compose 服务进入 healthy 状态
set -euo pipefail

cd "$(dirname "$0")/.."

SERVICE="${1:-anvil}"
TIMEOUT="${2:-30}"

echo "==> 等待 $SERVICE 进入 healthy（最多 ${TIMEOUT}s）..."

for ((i=0; i<TIMEOUT; i++)); do
  STATE=$(docker inspect --format='{{.State.Health.Status}}' "mychain-${SERVICE}" 2>/dev/null || echo "missing")
  case "$STATE" in
    healthy)
      echo "✅ $SERVICE 已 healthy"
      exit 0
      ;;
    starting|unhealthy|none)
      sleep 1
      ;;
    missing)
      sleep 1
      ;;
    *)
      sleep 1
      ;;
  esac
done

echo "❌ $SERVICE 在 ${TIMEOUT}s 内没有进入 healthy。当前状态：$STATE" >&2
docker logs --tail 50 "mychain-${SERVICE}" 2>&1 | sed 's/^/  /' >&2 || true
exit 1
