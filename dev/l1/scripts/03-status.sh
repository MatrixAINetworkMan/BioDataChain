#!/usr/bin/env bash
# 打印 L1 当前状态
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; source .env; set +a

# 用 127.0.0.1 不要 localhost：Ubuntu 24.04 的 /etc/hosts 默认让 localhost 先
# 解析成 IPv6 ::1，但 docker 只 bind 在 IPv4 127.0.0.1:8545，有些 curl 不会 fallback
# 就报 Error 7 "Failed to connect"
RPC="http://127.0.0.1:${HTTP_PORT:-8545}"

# geth 启动早期 RPC server 已经接受连接但 chain head 还没完全 ready，
# 个别 method（典型 eth_blockNumber）会瞬时返回空（curl exit 52）。
# 加 5s 超时 + 3 次重试 + 失败 fallback 到 {} 避免 set -e 让整个 status 退出。
rpc() {
  local method="$1" params="$2" out
  for _i in 1 2 3; do
    if out="$(curl -sf -m 5 -X POST "$RPC" \
        -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" 2>/dev/null)"; then
      echo "$out"
      return 0
    fi
    sleep 1
  done
  # 3 次都失败：返回空 JSON 让上层 jq 拿到 null
  echo '{}'
  return 0
}

hexdec() {
  # 防御性：空串 / 非 hex 都返回 0，避免 printf 报错让脚本退出
  case "$1" in
    0x*) printf '%d' "$1" 2>/dev/null || echo 0 ;;
    *)   echo 0 ;;
  esac
}

echo "===== L1 状态 ====="
echo "RPC URL       : $RPC"
if [[ -n "${PUBLIC_HOST:-}" ]]; then
  echo "Public RPC    : http://${PUBLIC_HOST}:${HTTP_PORT:-8545}"
  echo "Public WS     : ws://${PUBLIC_HOST}:${WS_PORT:-8546}"
fi

# 客户端版本
CLIENT="$(rpc web3_clientVersion '[]' | jq -r '.result // "?"')"
echo "Client        : $CLIENT"

# Chain ID
CHAIN_ID_HEX="$(rpc eth_chainId '[]' | jq -r '.result // "0x0"')"
echo "Chain ID      : $(hexdec "$CHAIN_ID_HEX")  ($CHAIN_ID_HEX)"

# Block #
BLOCK_HEX="$(rpc eth_blockNumber '[]' | jq -r '.result // "0x0"')"
echo "Block #       : $(hexdec "$BLOCK_HEX")  ($BLOCK_HEX)"

# Validator (Clique signers)
SIGNERS="$(rpc clique_getSigners '["latest"]' | jq -r '.result // [] | join(",")')"
echo "Clique signer : ${SIGNERS:-<none>}"

# Genesis hash（**关键**：L2 op-node 启动时要 lock 这个值）
GENESIS_HASH="$(rpc eth_getBlockByNumber '["0x0", false]' | jq -r '.result.hash // "?"')"
echo "Genesis hash  : $GENESIS_HASH"

# Genesis 时间戳
GENESIS_TS_HEX="$(rpc eth_getBlockByNumber '["0x0", false]' | jq -r '.result.timestamp // "0x0"')"
GENESIS_TS="$(hexdec "$GENESIS_TS_HEX")"
echo "Genesis time  : $(date -d @${GENESIS_TS} '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -r ${GENESIS_TS} '+%Y-%m-%d %H:%M:%S %Z') ($GENESIS_TS_HEX)"

# Latest hash
LATEST_HASH="$(rpc eth_getBlockByNumber '["latest", false]' | jq -r '.result.hash // "?"')"
echo "Latest hash   : $LATEST_HASH"

# Validator balance
if [[ -n "${VALIDATOR_ADDRESS:-}" ]]; then
  BAL_HEX="$(rpc eth_getBalance "[\"$VALIDATOR_ADDRESS\",\"latest\"]" | jq -r '.result // "0x0"')"
  # 把 wei 转成 ETH（保留 4 位小数）；用 python3 避免 bc 兼容性
  BAL_ETH="$(python3 -c "print(f'{int(\"$BAL_HEX\", 16) / 10**18:.4f}')" 2>/dev/null || echo "?")"
  echo "Validator     : $VALIDATOR_ADDRESS"
  echo "  balance     : ${BAL_ETH} ETH"
fi

# Pending tx
PENDING="$(rpc txpool_status '[]' | jq -r '.result.pending // "0x0"')"
QUEUED="$(rpc txpool_status '[]' | jq -r '.result.queued // "0x0"')"
echo "txpool pending: $(hexdec "$PENDING")   queued: $(hexdec "$QUEUED")"

echo ""
echo "===== MetaMask 添加网络 ====="
echo "  Network Name : ${L1_NETWORK_NAME:-mychain-l1}"
if [[ -n "${PUBLIC_HOST:-}" ]]; then
  echo "  RPC URL      : http://${PUBLIC_HOST}:${HTTP_PORT:-8545}"
else
  echo "  RPC URL      : http://<PUBLIC_HOST>:${HTTP_PORT:-8545}  ← 在 .env 设置 PUBLIC_HOST"
fi
echo "  Chain ID     : $(hexdec "$CHAIN_ID_HEX")"
echo "  Currency     : ETH"
