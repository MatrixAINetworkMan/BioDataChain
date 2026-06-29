#!/usr/bin/env bash
# 用 validator 账号转 ETH 到指定地址（dev/staging 测试用）
#
# 用法：bash scripts/04-fund.sh 0xabc... [amount_eth=1000]
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; source .env; set +a

TO="${1:?Usage: 04-fund.sh 0x... [amount_eth=1000]}"
AMOUNT_ETH="${2:-1000}"

if [[ -z "${VALIDATOR_ADDRESS:-}" ]]; then
  echo "❌ VALIDATOR_ADDRESS 为空。先 make init" >&2
  exit 1
fi

# 地址校验
if ! [[ "$TO" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "❌ 目标地址格式错误（必须 0x + 40 hex）: $TO" >&2
  exit 1
fi

AMOUNT_HEX_WEI="$(python3 -c "print(hex(int(${AMOUNT_ETH} * 10**18)))")"

RPC="http://127.0.0.1:${HTTP_PORT:-8545}"

echo "==> 转账 ${AMOUNT_ETH} ETH"
echo "    from: ${VALIDATOR_ADDRESS}"
echo "    to  : ${TO}"

RESP="$(curl -sf -X POST "$RPC" \
  -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"${VALIDATOR_ADDRESS}\",\"to\":\"${TO}\",\"value\":\"${AMOUNT_HEX_WEI}\"}]}")"

TX_HASH="$(echo "$RESP" | jq -r '.result // empty')"
ERR="$(echo "$RESP" | jq -r '.error.message // empty')"

if [[ -n "$ERR" ]]; then
  echo "❌ RPC 错误: $ERR" >&2
  exit 1
fi

echo "==> Tx hash: $TX_HASH"
echo "==> 等待打包（最多 30 秒）..."

for i in {1..30}; do
  RECEIPT="$(curl -sf -X POST "$RPC" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionReceipt\",\"params\":[\"${TX_HASH}\"]}" \
    | jq -r '.result // empty')"
  if [[ -n "$RECEIPT" && "$RECEIPT" != "null" ]]; then
    STATUS="$(echo "$RECEIPT" | jq -r '.status')"
    BLOCK_HEX="$(echo "$RECEIPT" | jq -r '.blockNumber')"
    if [[ "$STATUS" == "0x1" ]]; then
      echo "✅ 已打包 (block #$(printf '%d' "$BLOCK_HEX"))"
      # 查目标余额
      BAL_HEX="$(curl -sf -X POST "$RPC" \
        -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBalance\",\"params\":[\"${TO}\",\"latest\"]}" \
        | jq -r '.result')"
      BAL_ETH="$(python3 -c "print(f'{int(\"$BAL_HEX\", 16) / 10**18:.4f}')")"
      echo "    ${TO} balance = ${BAL_ETH} ETH"
      exit 0
    else
      echo "❌ Tx 失败 (status=$STATUS)" >&2
      exit 1
    fi
  fi
  sleep 1
done

echo "⚠️  30 秒内没拿到 receipt。Tx 可能还在 mempool，自己查：" >&2
echo "    curl ${RPC} -X POST -H 'Content-Type: application/json' \\" >&2
echo "      --data '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionReceipt\",\"params\":[\"${TX_HASH}\"]}'" >&2
exit 1
