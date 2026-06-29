#!/usr/bin/env bash
# ⚠️ 删除 L1 链所有数据，不可恢复
set -euo pipefail

cd "$(dirname "$0")/.."

cat <<EOF
⚠️  这会删除 L1 链所有数据：
    - docker container: mychain-l1-geth
    - docker volume   : mychain-l1-geth-data （所有区块、state）
    - 本地 keystore   : ./keystore/UTC--* （validator 私钥）
    - 本地 secrets    : ./secrets/password.txt
    - 渲染产物        : ./workdir/genesis.json
    - .env 里的 VALIDATOR_ADDRESS 字段会被清空

执行后必须重新 make init 重建链，新链跟当前链 genesis hash 不一样，
任何已部署的合约、连接的钱包都要重新走流程。
EOF

read -p $'\n输入 YES 确认: ' ans
if [[ "$ans" != "YES" ]]; then
  echo "取消"
  exit 0
fi

if [[ -f .env ]]; then
  docker compose --env-file .env down -v 2>/dev/null || true
else
  docker rm -f mychain-l1-geth 2>/dev/null || true
  docker volume rm -f mychain-l1-geth-data 2>/dev/null || true
fi

rm -rf keystore/UTC--* secrets/password.txt workdir/genesis.json password.txt

if [[ -f .env ]] && grep -qE '^VALIDATOR_ADDRESS=' .env; then
  sed -i.bak "s|^VALIDATOR_ADDRESS=.*|VALIDATOR_ADDRESS=|" .env
  rm -f .env.bak
fi

echo "✅ 已清空。重新部署：make init && make up"
