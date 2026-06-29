#!/usr/bin/env bash
# 端到端健康检查
set -euo pipefail

cd "$(dirname "$0")/.."

set -a; source .env; set +a

green() { printf "\033[32m✅ %s\033[0m\n" "$*"; }
red()   { printf "\033[31m❌ %s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m⚠️  %s\033[0m\n" "$*"; }

fail=0

# 1. anvil 出块
echo "[1/6] anvil 出块..."
B1=$(docker exec mychain-anvil cast block-number --rpc-url http://localhost:8545 2>/dev/null || echo "fail")
sleep 3
B2=$(docker exec mychain-anvil cast block-number --rpc-url http://localhost:8545 2>/dev/null || echo "fail")
if [[ "$B1" =~ ^[0-9]+$ && "$B2" =~ ^[0-9]+$ && $B2 -gt $B1 ]]; then
  green "anvil 在出块 ($B1 -> $B2)"
else
  red "anvil 没在出块 ($B1, $B2)"
  fail=1
fi

# 2. op-geth RPC
echo "[2/6] op-geth RPC..."
L2_BLOCK=$(curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:${L2_RPC_PORT} | jq -r '.result // empty' || true)
if [[ -n "$L2_BLOCK" ]]; then
  green "op-geth RPC 响应 (latest=$((L2_BLOCK)))"
else
  red "op-geth RPC 不可达"
  fail=1
fi

# 3. op-node sync 状态
echo "[3/6] op-node sync 状态..."
SYNC=$(curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
  http://localhost:${OP_NODE_RPC_PORT} | jq -r '.result.unsafe_l2.number // empty' || true)
if [[ -n "$SYNC" ]]; then
  green "op-node 不安全头 = $SYNC"
else
  red "op-node sync 状态异常"
  fail=1
fi

# 4. L2 出块速率
echo "[4/6] L2 出块（等 6s 看增长）..."
L2_B1=$(curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:${L2_RPC_PORT} | jq -r '.result' | xargs printf "%d\n" 2>/dev/null || echo 0)
sleep 6
L2_B2=$(curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:${L2_RPC_PORT} | jq -r '.result' | xargs printf "%d\n" 2>/dev/null || echo 0)
if [[ $L2_B2 -gt $L2_B1 ]]; then
  green "L2 在出块 ($L2_B1 -> $L2_B2)"
else
  red "L2 没在出块"
  fail=1
fi

# 5. CGT v2 flag
echo "[5/6] CGT v2 flag (L2 L1Block.isCustomGasToken)..."
# L1Block predeploy: 0x4200000000000000000000000000000000000015
# isCustomGasToken() 4byte: 0x70d2e0a4 (CGT v2 spec)
RES=$(curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x4200000000000000000000000000000000000015","data":"0x70d2e0a4"},"latest"],"id":1}' \
  http://localhost:${L2_RPC_PORT} | jq -r '.result // empty')
if [[ "$RES" == *"0000000000000000000000000000000000000000000000000000000000000001" ]]; then
  green "L1Block.isCustomGasToken() = true"
elif [[ "$RES" == *"0000000000000000000000000000000000000000000000000000000000000000" ]]; then
  yellow "L1Block.isCustomGasToken() = false（CGT 没启用！）"
  fail=1
elif [[ -z "$RES" ]]; then
  yellow "L1Block 未部署或 selector 不对（可能 op-contracts 版本不匹配）"
  fail=1
else
  yellow "L1Block.isCustomGasToken() 返回未知：$RES"
fi

# 6. NativeAssetLiquidity 余额（v6.0.0 实际地址 0x4200..0029）
echo "[6/6] NativeAssetLiquidity (0x4200..0029) 余额..."
NAL_BAL=$(curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0x4200000000000000000000000000000000000029","latest"],"id":1}' \
  http://localhost:${L2_RPC_PORT} | jq -r '.result // "0x0"')
# 余额可能远大于 2^63，不能用 printf %d，改用 python/bc
NAL_DEC=$(python3 -c "print(int('$NAL_BAL', 16))" 2>/dev/null || echo 0)
if [[ "$NAL_DEC" != "0" ]]; then
  NAL_ETH=$(python3 -c "print(f'{int(\"$NAL_BAL\", 16) / 10**18:,.2f}')" 2>/dev/null || echo "?")
  green "NativeAssetLiquidity 余额 = $NAL_BAL (${NAL_ETH} MAN)"
else
  red "NativeAssetLiquidity 余额为 0（CGT v2 创世预 mint 失败）"
  fail=1
fi

echo ""
if [[ $fail -eq 0 ]]; then
  green "==> 全部健康检查通过"
else
  red "==> $fail 项失败，跑 'make logs' 看日志"
  exit 1
fi
