#!/usr/bin/env bash
# 用 deployer EOA 给指定地址转 MAN（dev 阶段方便给团队成员发钱）
set -euo pipefail

cd "$(dirname "$0")/.."

set -a; source .env; set +a

TO="$1"
AMOUNT="$2"   # 单位 MAN，整数

if ! [[ "$TO" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "❌ TO 不是合法地址：$TO" >&2
  exit 1
fi
if ! [[ "$AMOUNT" =~ ^[0-9]+$ ]]; then
  echo "❌ AMOUNT 必须是正整数（单位 MAN）：$AMOUNT" >&2
  exit 1
fi

echo "==> 从 ${DEPLOYER_ADDRESS} 转 ${AMOUNT} MAN 到 ${TO} ..."

BEFORE=$(docker run --rm --network mychain-dev --entrypoint cast "${ANVIL_IMAGE}" \
  balance "$TO" --rpc-url http://op-geth:8545 2>/dev/null || echo 0)

docker run --rm --network mychain-dev --entrypoint cast "${ANVIL_IMAGE}" \
  send --private-key "${DEPLOYER_PRIVATE_KEY}" \
  "$TO" --value "${AMOUNT}ether" \
  --rpc-url http://op-geth:8545

AFTER=$(docker run --rm --network mychain-dev --entrypoint cast "${ANVIL_IMAGE}" \
  balance "$TO" --rpc-url http://op-geth:8545 2>/dev/null || echo 0)

echo ""
echo "✅ 完成"
echo "   收款地址  $TO"
echo "   转账前    $BEFORE wei"
echo "   转账后    $AFTER wei"
