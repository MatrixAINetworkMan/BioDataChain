#!/usr/bin/env bash
# =============================================================================
# 端到端验证：编译 + 部署一个 Faucet 合约到 L2，并真的调用一次。
#
# 依赖：docker、jq；不需要本地装 foundry / solc
# 全程通过 docker 跑 ghcr.io/foundry-rs/foundry:stable，挂同一个 docker network
# 直连 op-geth:8545（绕开公网/防火墙），失败也能拿到真实 revert 原因。
#
# 用法：
#   ./scripts/test-deploy.sh
# 可选环境变量覆盖：
#   DEPLOYER_PK   部署者私钥（默认 TEAM_ACCESS.md 自用钱包 #1）
#   RECIPIENT_PK  调 drip 的钱包私钥（默认 自用钱包 #2，必须有 gas）
#   FUND_AMOUNT   部署时给 Faucet 充多少 MAN（默认 1）
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "❌ .env 不存在，先 cp .env.example .env 并填好 PUBLIC_HOST" >&2
  exit 1
fi
set -a; source .env; set +a

# ---------- 默认参数 ----------
DEPLOYER_PK="${DEPLOYER_PK:-0x<DEPLOYER_PRIVATE_KEY>}"
DEPLOYER_ADDR="${DEPLOYER_ADDR:-0x<DEPLOYER_ADDRESS>}"
RECIPIENT_PK="${RECIPIENT_PK:-0x<RECIPIENT_PRIVATE_KEY>}"
RECIPIENT_ADDR="${RECIPIENT_ADDR:-0x<RECIPIENT_ADDRESS>}"
FUND_AMOUNT="${FUND_AMOUNT:-1}"

FOUNDRY_IMG="${ANVIL_IMAGE:-ghcr.io/foundry-rs/foundry:stable}"
NETWORK="mychain-dev"        # 主链 docker network 名
RPC_INTERNAL="http://op-geth:8545"
EXPLORER="http://${PUBLIC_HOST:-localhost}:${BLOCKSCOUT_PORT:-4000}"

# ---------- 检查 ----------
command -v jq >/dev/null || { echo "❌ 需要 jq，apt install jq"; exit 1; }
docker network inspect "$NETWORK" >/dev/null 2>&1 || { echo "❌ docker network $NETWORK 不存在，先 make dev-up"; exit 1; }

run_cast() {
  docker run --rm --network "$NETWORK" --entrypoint cast "$FOUNDRY_IMG" "$@"
}

run_forge() {
  docker run --rm -v "$PROJ:/work" -w /work --user "$(id -u):$(id -g)" \
    -e HOME=/work \
    --entrypoint forge "$FOUNDRY_IMG" "$@"
}

# ---------- 0. 链可达性 ----------
echo "==> 0. 检查 L2 RPC 可达"
CHAIN_ID="$(run_cast chain-id --rpc-url "$RPC_INTERNAL")"
BLOCK="$(run_cast block-number --rpc-url "$RPC_INTERNAL")"
echo "    chainId=$CHAIN_ID  最新块=$BLOCK"

DEPLOYER_BAL_WEI="$(run_cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC_INTERNAL")"
echo "    部署者 $DEPLOYER_ADDR 余额 = $(run_cast from-wei "$DEPLOYER_BAL_WEI") MAN"
if [[ "$DEPLOYER_BAL_WEI" == "0" ]]; then
  echo "❌ 部署者余额 0，先 make fund TO=$DEPLOYER_ADDR AMOUNT=10"
  exit 1
fi

# ---------- 1. 写 + 编译 Faucet ----------
PROJ="$(mktemp -d)"
trap "rm -rf $PROJ" EXIT
mkdir -p "$PROJ/src"

cat > "$PROJ/foundry.toml" <<'TOML'
[profile.default]
src = "src"
out = "out"
optimizer = true
optimizer_runs = 200
TOML

cat > "$PROJ/src/Faucet.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Faucet {
    event Drip(address indexed to, uint256 amount);

    uint256 public constant DRIP_AMOUNT = 0.01 ether;

    constructor() payable {}

    function drip() external {
        require(address(this).balance >= DRIP_AMOUNT, "empty");
        (bool ok, ) = msg.sender.call{value: DRIP_AMOUNT}("");
        require(ok, "send fail");
        emit Drip(msg.sender, DRIP_AMOUNT);
    }

    receive() external payable {}
}
SOL

echo ""
echo "==> 1. forge build"
run_forge build --silent
BYTECODE="$(jq -r '.bytecode.object' "$PROJ/out/Faucet.sol/Faucet.json")"
[[ -z "$BYTECODE" || "$BYTECODE" == "null" ]] && { echo "❌ 编译产物没拿到"; exit 1; }
echo "    bytecode 长度: ${#BYTECODE} 字符"

# ---------- 2. 部署 ----------
echo ""
echo "==> 2. 部署 Faucet（同时充 ${FUND_AMOUNT} MAN）"
DEPLOY_OUT="$(run_cast send \
  --rpc-url "$RPC_INTERNAL" \
  --private-key "$DEPLOYER_PK" \
  --value "${FUND_AMOUNT}ether" \
  --json \
  --create "$BYTECODE")"
echo "$DEPLOY_OUT" | jq '{contractAddress, blockNumber, gasUsed, status}'

CONTRACT="$(echo "$DEPLOY_OUT" | jq -r '.contractAddress')"
[[ -z "$CONTRACT" || "$CONTRACT" == "null" ]] && { echo "❌ 没拿到合约地址"; exit 1; }
echo "    Faucet @ $CONTRACT"

# ---------- 3. 校验链上 code 不为空 ----------
echo ""
echo "==> 3. 校验 code(addr) != 0x"
CODE_LEN="$(run_cast code "$CONTRACT" --rpc-url "$RPC_INTERNAL" | wc -c)"
echo "    bytecode on-chain 长度 = $CODE_LEN 字符"
[[ "$CODE_LEN" -lt 10 ]] && { echo "❌ on-chain code 是空，部署失败"; exit 1; }

FAUCET_BAL="$(run_cast balance "$CONTRACT" --rpc-url "$RPC_INTERNAL")"
echo "    Faucet 当前余额 = $(run_cast from-wei "$FAUCET_BAL") MAN"

# ---------- 4. 用 #2 调 drip()，验真的能领钱 ----------
echo ""
echo "==> 4. 用 $RECIPIENT_ADDR 调 drip()"
RECIP_BAL_BEFORE="$(run_cast balance "$RECIPIENT_ADDR" --rpc-url "$RPC_INTERNAL")"
echo "    调用前 recipient 余额 = $(run_cast from-wei "$RECIP_BAL_BEFORE") MAN"

DRIP_OUT="$(run_cast send \
  --rpc-url "$RPC_INTERNAL" \
  --private-key "$RECIPIENT_PK" \
  "$CONTRACT" "drip()" \
  --json)"
echo "$DRIP_OUT" | jq '{transactionHash, blockNumber, gasUsed, status}'

RECIP_BAL_AFTER="$(run_cast balance "$RECIPIENT_ADDR" --rpc-url "$RPC_INTERNAL")"
echo "    调用后 recipient 余额 = $(run_cast from-wei "$RECIP_BAL_AFTER") MAN"

# 大数减法用 python 处理（bash 64bit 装不下 wei）
DELTA_WEI="$(python3 -c "print($RECIP_BAL_AFTER - $RECIP_BAL_BEFORE)")"
echo "    净变化 = $DELTA_WEI wei（drip 发 1e16 wei；扣 gas 后通常是负值，看上面 status=0x1 即成功）"

FAUCET_BAL_AFTER="$(run_cast balance "$CONTRACT" --rpc-url "$RPC_INTERNAL")"
echo "    Faucet 余额 = $(run_cast from-wei "$FAUCET_BAL_AFTER") MAN（应该比之前少 0.01）"

# ---------- 5. 总结 ----------
echo ""
echo "========================================================================"
echo "✅ Faucet 端到端跑通"
echo ""
echo "合约地址：       $CONTRACT"
echo "部署 tx：        $(echo "$DEPLOY_OUT" | jq -r '.transactionHash')"
echo "drip tx：        $(echo "$DRIP_OUT" | jq -r '.transactionHash')"
echo ""
echo "在 Blockscout 看："
echo "  合约：    $EXPLORER/address/$CONTRACT"
echo "  部署 tx： $EXPLORER/tx/$(echo "$DEPLOY_OUT" | jq -r '.transactionHash')"
echo "  drip tx： $EXPLORER/tx/$(echo "$DRIP_OUT" | jq -r '.transactionHash')"
echo "========================================================================"
