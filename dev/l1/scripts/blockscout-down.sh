#!/usr/bin/env bash
# 停止 Blockscout（不删数据；想删数据用 make blockscout-clean）
set -euo pipefail

cd "$(dirname "$0")/../blockscout"

docker compose --env-file ../.env down
echo "✅ Blockscout 已停止（数据保留：volumes mychain-l1-bs-db / -redis / -stats-db）"
