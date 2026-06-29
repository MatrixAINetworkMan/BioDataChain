#!/usr/bin/env bash
# 通过 LiquidityController predeploy 从 NativeAssetLiquidity 储备直接给地址 mint MAN。
#
# 跟 scripts/fund.sh 的区别：
#   - fund.sh：用 deployer EOA 普通转账，额度受 deployer 余额限制
#   - mint.sh：调 LC.mint()，从 NAL 20 亿 MAN 储备里"虚空造币"，给同事
#              发 1 千万都没事；不消耗 deployer 余额（只花 gas）
#
# 前置：
#   - DEPLOYER 必须是 LC owner（dev 模式下 OWNER_MULTISIG = deployer，✓）
#   - DEPLOYER 必须是 authorized minter；脚本会检测，没授权时自动调 authorizeMinter()
#
# 用法：
#   bash scripts/mint.sh 0xabc...address 1000000
#   # 或通过 Makefile：
#   make mint TO=0x... AMOUNT=1000000
set -euo pipefail

cd "$(dirname "$0")/.."

set -a; source .env; set +a

TO="$1"
AMOUNT="$2"   # 单位 MAN，整数

if ! [[ "$TO" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "❌ TO 不是合法地址：$TO" >&2
  exit 1
fi
if ! [[ "$AMOUNT" =~ ^[0-9]+$ ]] || [[ "$AMOUNT" == "0" ]]; then
  echo "❌ AMOUNT 必须是正整数（单位 MAN）：$AMOUNT" >&2
  exit 1
fi

# 系统 predeploy 地址（v6.0.0 CGT v2）
LC=0x420000000000000000000000000000000000002A
NAL=0x4200000000000000000000000000000000000029

cast_l2()      { docker run --rm --network mychain-dev --entrypoint cast "${ANVIL_IMAGE}" "$@" --rpc-url http://op-geth:8545; }
cast_send_l2() { docker run --rm --network mychain-dev --entrypoint cast "${ANVIL_IMAGE}" send --private-key "${DEPLOYER_PRIVATE_KEY}" "$@" --rpc-url http://op-geth:8545; }

# wei -> MAN 显示（用 python 处理大数，bash 算不动 10^27）
wei2auv() { python3 -c "import sys; w=int(sys.stdin.read().strip()); print(f'{w/10**18:,.4f}')"; }

# 1 MAN = 10^18 wei；用 python 算 AMOUNT * 10^18（bash 整数算不动）
AMOUNT_WEI=$(python3 -c "print($AMOUNT * 10**18)")

# ---------------------------------------------------------------------------
# 1. 确认 LC owner = deployer（否则我们调不了 authorizeMinter）
# ---------------------------------------------------------------------------
OWNER=$(cast_l2 call "$LC" "owner()(address)" 2>/dev/null | tr '[:upper:]' '[:lower:]')
DEP_LOWER=$(echo "$DEPLOYER_ADDRESS" | tr '[:upper:]' '[:lower:]')
if [[ "$OWNER" != "$DEP_LOWER" ]]; then
  echo "❌ LC owner ($OWNER) != deployer ($DEP_LOWER)"
  echo "   dev 模式默认 owner = OWNER_MULTISIG = deployer。"
  echo "   如果你换过 OWNER_MULTISIG，得用对应私钥来 authorize / mint。" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. 确认 NAL 储备充足（bash 算不动 10^27 大数，用 python 比较）
# ---------------------------------------------------------------------------
NAL_BAL=$(cast_l2 balance "$NAL")
if python3 -c "import sys; sys.exit(0 if int('$AMOUNT_WEI') > int('$NAL_BAL') else 1)"; then
  echo "❌ NAL 储备不足：要 mint $AMOUNT MAN，但 NAL 只有 $(echo "$NAL_BAL" | wei2auv) MAN" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. 检测 deployer 是否已经是 authorized minter；没授权就 authorize 一次（幂等）
# ---------------------------------------------------------------------------
IS_MINTER=$(cast_l2 call "$LC" "minters(address)(bool)" "$DEPLOYER_ADDRESS" 2>/dev/null | tr -d ' ')
if [[ "$IS_MINTER" != "true" ]]; then
  echo "==> deployer 还不是 authorized minter，先 authorizeMinter() ..."
  cast_send_l2 "$LC" "authorizeMinter(address)" "$DEPLOYER_ADDRESS" > /dev/null
fi

# ---------------------------------------------------------------------------
# 4. mint
# ---------------------------------------------------------------------------
BEFORE=$(cast_l2 balance "$TO" 2>/dev/null || echo "0")
echo "==> LC.mint($TO, $AMOUNT MAN) ..."
cast_send_l2 "$LC" "mint(address,uint256)" "$TO" "$AMOUNT_WEI" \
  | grep -E "transactionHash|status|gasUsed" | head -3

# ---------------------------------------------------------------------------
# 5. 结果
# ---------------------------------------------------------------------------
AFTER=$(cast_l2 balance "$TO" 2>/dev/null || echo "0")
NAL_AFTER=$(cast_l2 balance "$NAL")

echo ""
echo "✅ 完成"
echo "   收款地址      $TO"
echo "   转账前余额    $(echo "$BEFORE" | wei2auv) MAN"
echo "   转账后余额    $(echo "$AFTER"  | wei2auv) MAN"
echo "   NAL 剩余储备  $(echo "$NAL_AFTER" | wei2auv) MAN"
