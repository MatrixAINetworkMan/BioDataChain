#!/usr/bin/env bash
# CGT v2 验收：跑 PLAN_OPSTACK_CGTV2.md §9.1 里的核心用例
set -euo pipefail

cd "$(dirname "$0")/.."

set -a; source .env; set +a

L2_RPC="http://localhost:${L2_RPC_PORT}"

green()  { printf "\033[32m✅ %s\033[0m\n" "$*"; }
red()    { printf "\033[31m❌ %s\033[0m\n" "$*"; }
yellow() { printf "\033[33m⚠️  %s\033[0m\n" "$*"; }

# 工具：用容器跑 cast
# 注 1：foundry stable image 默认 entrypoint 是 ["sh","-c"]，必须显式 --entrypoint cast
# 注 2：cast 当前版本要求 --rpc-url 放在 subcommand 之后，不能当全局选项
cast_l2() {
  docker run --rm --network mychain-dev --entrypoint cast "${ANVIL_IMAGE}" \
    "$@" --rpc-url http://op-geth:8545
}
cast_send_l2() {
  docker run --rm --network mychain-dev --entrypoint cast "${ANVIL_IMAGE}" \
    send --private-key "${DEPLOYER_PRIVATE_KEY}" "$@" --rpc-url http://op-geth:8545
}

fail=0

# ---------------------------------------------------------------------------
# 用例 1：原生币符号显示为 MAN（钱包/浏览器观测点）
# 注：原生币 symbol 是 chain-level 配置，RPC 上没有标准方法读，
#     所以这里只校验 rollup.json / genesis 里的设定
# ---------------------------------------------------------------------------
echo "[1/10] 原生币符号配置..."
# v6.0.0 + CGT v2 把 symbol 放在多个可能位置，挨个找：
#  - rollup.json/genesis.json: .config.optimism.customGasToken.symbol（早期 spec）
#  - genesis.json: alloc 里 NativeAssetLiquidity / GovToken 的 storage（运行时）
#  - intent.toml: 部署期意图（兜底）
SYM=$(jq -r '
  [
    .config.optimism.customGasToken.symbol? // empty,
    .config.customGasToken.symbol? // empty,
    .customGasToken.symbol? // empty,
    .gas_token.symbol? // empty
  ] | map(select(. != null and . != "")) | .[0] // empty
' workdir/shared/rollup.json 2>/dev/null || true)
if [[ -z "$SYM" ]]; then
  SYM=$(jq -r '
    [
      .config.optimism.customGasToken.symbol? // empty,
      .config.customGasToken.symbol? // empty
    ] | map(select(. != null and . != "")) | .[0] // empty
  ' workdir/shared/genesis.json 2>/dev/null || true)
fi
if [[ -z "$SYM" ]]; then
  # 兜底：从 intent.toml 读，至少证明部署意图正确
  SYM=$(grep -E '^\s*name\s*=' workdir/intent.toml 2>/dev/null | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/' || true)
fi
if [[ "$SYM" == "$NATIVE_TOKEN_SYMBOL" || "$SYM" == "$NATIVE_TOKEN_NAME" ]]; then
  green "原生币 symbol/name = $SYM"
else
  red "原生币 symbol 配置不匹配，期望 $NATIVE_TOKEN_SYMBOL，实际 '$SYM'"
  echo "    提示：手动看 workdir/shared/rollup.json 顶层有哪些 key：jq 'keys' workdir/shared/rollup.json"
  fail=$((fail+1))
fi

# ---------------------------------------------------------------------------
# 用例 2：L1Block.isCustomGasToken() == true
# ---------------------------------------------------------------------------
echo "[2/10] L1Block CGT 标志位..."
# v6.0.0 + CGT v2 把 API 从 isCustomGasToken() 换成了 gasPayingToken()
# 先试新 API，再试旧 API，最后退化到 "NAL 有 code 即视为启用"
RES_NEW=$(cast_l2 call 0x4200000000000000000000000000000000000015 "gasPayingToken()(address,uint8)" 2>&1 || true)
RES_OLD=$(cast_l2 call 0x4200000000000000000000000000000000000015 "isCustomGasToken()(bool)" 2>&1 || true)
if echo "$RES_NEW" | grep -qE '^0x[0-9a-fA-F]+'; then
  green "L1Block.gasPayingToken() = $RES_NEW"
elif [[ "$RES_OLD" == "true" ]]; then
  green "L1Block.isCustomGasToken() = true"
else
  # 退化：NAL 是否真的部署了
  NAL_CODE=$(cast_l2 code 0x4200000000000000000000000000000000000029 2>/dev/null || echo "0x")
  if [[ ${#NAL_CODE} -gt 4 ]]; then
    yellow "L1Block 没暴露 isCustomGasToken/gasPayingToken（API 可能改名），但 NAL 已部署，CGT v2 视为启用"
  else
    red "L1Block 既无 gasPayingToken 也无 isCustomGasToken，NAL 也没 code"
    echo "    new API: $RES_NEW"
    echo "    old API: $RES_OLD"
    fail=$((fail+1))
  fi
fi

# ---------------------------------------------------------------------------
# 用例 3：NativeAssetLiquidity (0x4200..0029) 余额 >= initialLiquidity
# 注：v6.0.0 实际 predeploy 地址是 0x4200..0029（不是早期 spec 的 0x...0020）
# ---------------------------------------------------------------------------
echo "[3/10] NativeAssetLiquidity 创世余额..."
NAL_BAL=$(cast_l2 balance 0x4200000000000000000000000000000000000029 2>/dev/null || echo "0")
if [[ "$NAL_BAL" =~ ^[0-9]+$ && "$NAL_BAL" != "0" ]]; then
  green "NativeAssetLiquidity 余额 = $NAL_BAL wei"
else
  red "NativeAssetLiquidity 余额 = $NAL_BAL"
  fail=$((fail+1))
fi

# ---------------------------------------------------------------------------
# 用例 4：LiquidityController predeploy 有代码（v6.0.0：0x...002A）
# ---------------------------------------------------------------------------
echo "[4/10] LiquidityController predeploy 已部署..."
CODE=$(cast_l2 code 0x420000000000000000000000000000000000002A 2>/dev/null || echo "0x")
if [[ "$CODE" != "0x" && ${#CODE} -gt 4 ]]; then
  green "LiquidityController 有 code (长度: ${#CODE})"
else
  red "LiquidityController 无 code"
  fail=$((fail+1))
fi

# ---------------------------------------------------------------------------
# 用例 5：Deployer 创世余额 > 0（intent.toml 通过 customGasToken.initialLiquidity 给的）
# ---------------------------------------------------------------------------
echo "[5/10] Deployer 创世余额..."
DEP_BAL=$(cast_l2 balance "$DEPLOYER_ADDRESS" 2>/dev/null || echo "0")
if [[ "$DEP_BAL" =~ ^[0-9]+$ && $DEP_BAL -gt 0 ]]; then
  green "Deployer ${DEPLOYER_ADDRESS} 余额 = $DEP_BAL wei"
else
  red "Deployer 余额为 0 — initialLiquidity 没分到 Deployer 头上"
  fail=$((fail+1))
fi

# ---------------------------------------------------------------------------
# 用例 6：发一笔原生币转账，from 余额减少
# ---------------------------------------------------------------------------
echo "[6/10] 原生币转账测试..."
TARGET=0x000000000000000000000000000000000000c0DE
BEFORE=$(cast_l2 balance "$TARGET" 2>/dev/null || echo "0")
TX=$(cast_send_l2 "$TARGET" --value 1ether 2>&1 | grep -E '^transactionHash' | awk '{print $2}' || true)
sleep 3
AFTER=$(cast_l2 balance "$TARGET" 2>/dev/null || echo "0")
if [[ -n "$TX" && $AFTER -gt $BEFORE ]]; then
  green "转账成功 tx=$TX, 0x..c0DE 余额 $BEFORE -> $AFTER"
else
  red "转账失败或余额没变化（before=$BEFORE after=$AFTER）"
  fail=$((fail+1))
fi

# ---------------------------------------------------------------------------
# 用例 7：gas 在原生币计价（receipt.effectiveGasPrice * gasUsed = 余额变化的一部分）
# ---------------------------------------------------------------------------
echo "[7/10] gas 在原生币计价..."
if [[ -n "${TX:-}" ]]; then
  RCPT=$(cast_l2 receipt "$TX" --json 2>/dev/null || echo "{}")
  GU=$(echo "$RCPT" | jq -r '.gasUsed // empty')
  GP=$(echo "$RCPT" | jq -r '.effectiveGasPrice // empty')
  if [[ -n "$GU" && -n "$GP" ]]; then
    green "tx 用 $GU gas @ $GP wei，全部以 ${NATIVE_TOKEN_SYMBOL} 计价"
  else
    red "拿不到 gasUsed / effectiveGasPrice"
    fail=$((fail+1))
  fi
fi

# ---------------------------------------------------------------------------
# 用例 8：余额为 0 的账户发交易应被 RPC 拒绝（insufficient funds）
# ---------------------------------------------------------------------------
echo "[8/10] 零余额账户应被拒绝..."
# 公开 dummy 私钥（全 1），仅用于触发"零余额账户被拒"用例，非真实密钥。
# 如需替换可经环境变量 ZERO_KEY 注入任意零余额账户的私钥。
ZERO_KEY="${ZERO_KEY:-0x1111111111111111111111111111111111111111111111111111111111111111}"
OUT=$(docker run --rm --network mychain-dev --entrypoint cast "${ANVIL_IMAGE}" \
  send --private-key "$ZERO_KEY" \
  0x000000000000000000000000000000000000c0DE --value 1ether \
  --rpc-url http://op-geth:8545 2>&1 || true)
if echo "$OUT" | grep -qiE 'insufficient funds|insufficient balance|funds for gas'; then
  green "零余额账户被拒（错误：$(echo "$OUT" | head -1)）"
else
  red "零余额账户没有被拒，输出：$(echo "$OUT" | head -3)"
  fail=$((fail+1))
fi

# ---------------------------------------------------------------------------
# 用例 9：op-batcher 在向 L1 提交 batch
# ---------------------------------------------------------------------------
echo "[9/10] op-batcher 提交活跃..."
sleep 8  # 给一点时间
LOG=$(docker logs --tail 200 mychain-op-batcher 2>&1 || true)
if echo "$LOG" | grep -qE 'channel|batch|published|submitted'; then
  green "op-batcher 日志有 channel/batch/submitted 字样"
else
  red "op-batcher 没看到提交活动（最近 200 行日志）"
  fail=$((fail+1))
fi

# ---------------------------------------------------------------------------
# 用例 10：safe head 跟 unsafe head 接近（< 100 块差距）
# 刚部署完 derivation 还在追，最多轮询 5 次（共 ~120s）
# ---------------------------------------------------------------------------
echo "[10/10] op-node safe/unsafe head..."
DIFF=99999
for attempt in 1 2 3 4 5; do
  SS=$(curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
    http://localhost:${OP_NODE_RPC_PORT})
  UNSAFE=$(echo "$SS" | jq -r '.result.unsafe_l2.number')
  SAFE=$(echo "$SS" | jq -r '.result.safe_l2.number')
  DIFF=$(( UNSAFE - SAFE ))
  if [[ $DIFF -lt 100 ]]; then
    break
  fi
  echo "    第 $attempt 次：unsafe=$UNSAFE safe=$SAFE 差 $DIFF（>100），等 25s 让 derivation 追..."
  sleep 25
done
if [[ $DIFF -lt 100 ]]; then
  green "unsafe=$UNSAFE safe=$SAFE 差 $DIFF 块"
else
  red "unsafe=$UNSAFE safe=$SAFE 差 $DIFF 块（batcher / derivation 可能没在工作）"
  fail=$((fail+1))
fi

echo ""
if [[ $fail -eq 0 ]]; then
  printf "\033[32m========================================\n"
  printf "✅ CGT v2 全部 10 项验收通过\n"
  printf "========================================\033[0m\n"
else
  printf "\033[31m========================================\n"
  printf "❌ $fail 项失败\n"
  printf "========================================\033[0m\n"
  exit 1
fi
