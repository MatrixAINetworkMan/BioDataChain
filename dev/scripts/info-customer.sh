#!/usr/bin/env bash
# =============================================================================
# 给跨链桥 / 第三方接入用的链信息（客户友好格式）
#
# 自动从 .env + workdir/shared/l1-addresses.env + 链上 RPC query 拼出来。
#
# 用法：
#   bash scripts/info-customer.sh              # 标准输出
#   bash scripts/info-customer.sh > info.txt   # 存到文件发客户
# =============================================================================

set -uo pipefail
cd "$(dirname "$0")/.."

# ---------- 加载配置 ----------
set -a
[[ -f .env ]] && source .env
[[ -f .env.flashblocks ]] && source .env.flashblocks
[[ -f workdir/shared/l1-addresses.env ]] && source workdir/shared/l1-addresses.env
set +a

PUBLIC_HOST=${PUBLIC_HOST:-127.0.0.1}
# 链显示名：优先从 Blockscout 模板读，否则用 .env 的 CHAIN_NAME，最后 fallback
CHAIN_NAME=${CHAIN_NAME:-$(grep -h '^NEXT_PUBLIC_NETWORK_SHORT_NAME=' blockscout/envs/frontend.env.tpl 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' || echo "MAN")}
CHAIN_NAME=${CHAIN_NAME:-MAN}
L1_CHAIN_ID=${L1_CHAIN_ID:-901}
L2_CHAIN_ID=${L2_CHAIN_ID:-42170}
L2_BLOCK_TIME=${L2_BLOCK_TIME:-3}
L2_GAS_LIMIT=${L2_GAS_LIMIT:-60000000}
NATIVE_TOKEN_NAME=${NATIVE_TOKEN_NAME:-Matrix AI Network}
NATIVE_TOKEN_SYMBOL=${NATIVE_TOKEN_SYMBOL:-MAN}
L2_RPC_HTTP_PORT=${OP_GETH_PORT:-9545}
L2_RPC_WS_PORT=${OP_GETH_WS_PORT:-9546}
L1_RPC_HTTP_PORT=${L1_PORT:-8545}
EXPLORER_URL=${EXPLORER_URL:-https://dev.example.com}

L2_RPC_HTTP="http://${PUBLIC_HOST}:${L2_RPC_HTTP_PORT}"
L2_RPC_WS="ws://${PUBLIC_HOST}:${L2_RPC_WS_PORT}"
L1_RPC_HTTP="http://${PUBLIC_HOST}:${L1_RPC_HTTP_PORT}"

# L2_CHAIN_ID_HEX 32-byte padded
L2_HEX=$(printf '0x%064x' "$L2_CHAIN_ID")

# ---------- RPC helpers（容器内调用，避免端口暴露问题） ----------
rpc() {
  local url=$1 method=$2 params=${3:-[]}
  docker run --rm --network mychain-dev curlimages/curl:latest -s --max-time 5 -X POST "$url" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":1}" 2>/dev/null
}
hex2dec() { python3 -c "import sys; v=sys.stdin.read().strip(); print(int(v,16) if v.startswith('0x') else v)" 2>/dev/null || echo "?"; }
wei2eth() { python3 -c "import sys; print(f'{int(sys.stdin.read().strip(),16)/1e18:,.4f}')" 2>/dev/null || echo "?"; }

# L2 query
L2_RPC_INTERNAL="http://op-geth:8545"
L2_HEAD=$(rpc "$L2_RPC_INTERNAL" eth_blockNumber | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "?")
L2_CHAINID_RPC=$(rpc "$L2_RPC_INTERNAL" eth_chainId | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "?")
L2_GASPRICE=$(rpc "$L2_RPC_INTERNAL" eth_gasPrice | python3 -c "import json,sys; print(f\"{int(json.load(sys.stdin)['result'],16)/1e9:.4f}\")" 2>/dev/null || echo "?")
NAL_ADDR="0x4200000000000000000000000000000000000029"
NAL_BAL=$(rpc "$L2_RPC_INTERNAL" eth_getBalance "[\"$NAL_ADDR\",\"latest\"]" | python3 -c "import json,sys; print(f\"{int(json.load(sys.stdin)['result'],16)/1e18:,.4f}\")" 2>/dev/null || echo "?")
CGT_V2_ON="false"
if [[ "$NAL_BAL" != "?" && "$NAL_BAL" != "0.0000" ]]; then CGT_V2_ON="true"; fi

# L1 query
L1_RPC_INTERNAL=${L1_RPC_URL_INTERNAL:-http://anvil:8545}
L1_HEAD=$(rpc "$L1_RPC_INTERNAL" eth_blockNumber | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "?")
L1_CHAINID_RPC=$(rpc "$L1_RPC_INTERNAL" eth_chainId | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "?")

# Owner of LiquidityController (CGT v2 admin)
LC_ADDR="0x420000000000000000000000000000000000002A"
LC_OWNER_RAW=$(rpc "$L2_RPC_INTERNAL" eth_call "[{\"to\":\"$LC_ADDR\",\"data\":\"0x8da5cb5b\"},\"latest\"]" 2>/dev/null | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',''); print('0x'+r[-40:]) if len(r)>=42 else print('?')" 2>/dev/null || echo "?")

cat <<EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║           ${CHAIN_NAME} L2 — 链基本信息（跨链桥 / 第三方接入版）
╚══════════════════════════════════════════════════════════════════════════════╝

【1. L2 网络（${NATIVE_TOKEN_SYMBOL} / ${NATIVE_TOKEN_SYMBOL} 自定义原生 gas token）】
  Chain Name        ${CHAIN_NAME}
  Chain ID          ${L2_CHAIN_ID}  (hex ${L2_HEX})
  RPC HTTP          ${L2_RPC_HTTP}
  RPC WebSocket     ${L2_RPC_WS}
  Block time        ${L2_BLOCK_TIME}s
  Gas limit         ${L2_GAS_LIMIT}
  Native token      ${NATIVE_TOKEN_SYMBOL} (${NATIVE_TOKEN_NAME})  decimals=18
  CGT v2            ${CGT_V2_ON}
  Latest head       ${L2_HEAD}
  eth_gasPrice      ${L2_GASPRICE} gwei
  RPC chainId       ${L2_CHAINID_RPC}
  NAL pool balance  ${NAL_BAL} ${NATIVE_TOKEN_SYMBOL}（CGT v2 流动性池总量）

【2. L1 网络】
  Chain ID          ${L1_CHAIN_ID}
  RPC HTTP          ${L1_RPC_HTTP}
  Block time        2s
  Latest head       ${L1_HEAD}
  RPC chainId       ${L1_CHAINID_RPC}

【3. L1 合约地址（dev 阶段 op-deployer 部署，地址会随 L1 重建而变）】
  OptimismPortal              ${OPTIMISM_PORTAL_PROXY:-?}
    └ 用途：L1 → L2 存款入口；CGT v2 链下，存原生币 (${NATIVE_TOKEN_SYMBOL})
            走 depositERC20Transaction()
  L1StandardBridge            ${L1_STANDARD_BRIDGE_PROXY:-?}
    └ 用途：L1 → L2 ERC-20 / ERC-721 桥接（标准模板）
  L1CrossDomainMessenger      ${L1_CROSS_DOMAIN_MESSENGER_PROXY:-?}
    └ 用途：L1 ↔ L2 任意合约调用消息传递
  L1ERC721Bridge              ${L1_ERC721_BRIDGE_PROXY:-?}
  OptimismMintableERC20Factory ${OPTIMISM_MINTABLE_ERC20_FACTORY_PROXY:-?}
    └ 用途：L1 上一键部署对应 L2 原生 ERC-20 的桥接版
  SystemConfig                ${SYSTEM_CONFIG_PROXY:-?}
    └ 用途：链参数 / batcher / unsafeBlockSigner / gasPayingToken() 等
  DisputeGameFactory          ${DISPUTE_GAME_FACTORY_PROXY:-?}
  AnchorStateRegistry         ${ANCHOR_STATE_REGISTRY_PROXY:-?}
  EthLockbox                  ${ETH_LOCKBOX_PROXY:-?}
  ProxyAdmin                  ${PROXY_ADMIN:-?}

【4. L2 预部署合约（标准 predeploy；所有 OP Stack L2 都一样）】
  L2CrossDomainMessenger      0x4200000000000000000000000000000000000007
    └ 用途：L2 → L1 任意合约调用消息传递（对端 = L1CrossDomainMessenger）
  L2StandardBridge            0x4200000000000000000000000000000000000010
    └ 用途：L2 → L1 ERC-20 / ERC-721 桥接（对端 = L1StandardBridge）
  L2ToL1MessagePasser         0x4200000000000000000000000000000000000016
    └ 用途：L2 提款最底层（L2StandardBridge 内部用，第三方桥也可直调）
  L2ERC721Bridge              0x4200000000000000000000000000000000000014
  OptimismMintableERC20Factory 0x4200000000000000000000000000000000000012
  L1Block                     0x4200000000000000000000000000000000000015
    └ 用途：L2 上读 L1 最新 block hash / number / base fee / isCustomGasToken
  WETH (= W${NATIVE_TOKEN_SYMBOL} in CGT v2)     0x4200000000000000000000000000000000000006
    └ 用途：原生 ${NATIVE_TOKEN_SYMBOL} 的 ERC-20 包装版（DEX / DeFi 用）
  SequencerFeeVault           0x4200000000000000000000000000000000000011
  BaseFeeVault                0x4200000000000000000000000000000000000019
  L1FeeVault                  0x420000000000000000000000000000000000001A
  GasPriceOracle              0x420000000000000000000000000000000000000F
  NativeAssetLiquidity (NAL)  ${NAL_ADDR}  [CGT v2]
    └ 用途：原生 ${NATIVE_TOKEN_SYMBOL} 的总流动性池（创世预 mint ~1e9）
  LiquidityController (LC)    ${LC_ADDR}  [CGT v2]
    └ 用途：owner 可 authorizeMinter + mint，从 NAL 释放 ${NATIVE_TOKEN_SYMBOL} 给任意地址
            dev 下 owner = ${LC_OWNER_RAW}

【5. 区块浏览器】
  Blockscout                  ${EXPLORER_URL}
  Blockscout API              ${EXPLORER_URL}/api/v2

EOF
