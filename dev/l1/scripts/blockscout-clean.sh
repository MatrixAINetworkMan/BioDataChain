#!/usr/bin/env bash
# ⚠️ 删除 Blockscout 所有数据（重新 blockscout-up 会从头索引）
# 这跟 L1 链数据 (mychain-l1-geth-data) 无关，L1 链不受影响
set -euo pipefail

cd "$(dirname "$0")/.."

cat <<EOF
⚠️  这会删除 Blockscout 索引数据：
    - mychain-l1-bs-db        (Blockscout 主 DB)
    - mychain-l1-bs-redis     (缓存)
    - mychain-l1-bs-stats-db  (统计 DB)

L1 链数据 (mychain-l1-geth-data) 不受影响。
重启后 Blockscout 会从 block 0 重新索引整条 L1（dev 阶段几分钟）。
EOF

read -p $'\n输入 YES 确认: ' ans
if [[ "$ans" != "YES" ]]; then
  echo "取消"
  exit 0
fi

cd blockscout
docker compose --env-file ../.env down -v
echo "✅ Blockscout 数据已清空。重建：make blockscout-up"
