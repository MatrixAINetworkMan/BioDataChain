#!/usr/bin/env bash
# 打印外部访问 URL（团队同事看这个）
set -euo pipefail

cd "$(dirname "$0")/.."

set -a; source .env; set +a

H="${PUBLIC_HOST:-<未设置 PUBLIC_HOST>}"

# Blockscout 浏览器入口：优先用 BLOCKSCOUT_PUBLIC_URL（反代 / 域名），否则回退 IP+端口
if [[ -n "${BLOCKSCOUT_PUBLIC_URL:-}" ]]; then
  EXPLORER_URL="${BLOCKSCOUT_PUBLIC_URL%/}"
  EXPLORER_HEALTH_URL="${EXPLORER_URL}/api/v2/blocks?limit=1"
  EXPLORER_MODE="reverse-proxy"
else
  EXPLORER_URL="http://${H}:${BLOCKSCOUT_PORT}"
  EXPLORER_HEALTH_URL="http://${H}:${BLOCKSCOUT_API_PORT}/api/v2/blocks?limit=1"
  EXPLORER_MODE="direct"
fi

# Currency 显示：name 跟 symbol 一样就只印一次，省得出现 "MAN (MAN)" 这种冗余
if [[ "$NATIVE_TOKEN_NAME" == "$NATIVE_TOKEN_SYMBOL" ]]; then
  CURRENCY_DISPLAY="$NATIVE_TOKEN_SYMBOL"
else
  CURRENCY_DISPLAY="$NATIVE_TOKEN_SYMBOL ($NATIVE_TOKEN_NAME)"
fi

cat <<EOF

╔═══════════════════════════════════════════════════════════════════════╗
║              MAN L2 — dev 环境访问信息                           ║
╚═══════════════════════════════════════════════════════════════════════╝

【L2 网络（CGT v2 + 自定义原生资产 ${NATIVE_TOKEN_SYMBOL}）】
  RPC URL          http://${H}:${L2_RPC_PORT}
  WebSocket        ws://${H}:${L2_WS_PORT}
  Chain ID         ${L2_CHAIN_ID}
  Currency         ${CURRENCY_DISPLAY}
  Explorer         ${EXPLORER_URL}

【L1 (anvil 假以太坊)】
  RPC URL          http://${H}:${ANVIL_PORT}
  Chain ID         ${L1_CHAIN_ID}
  预设账户         10 个，每个 10000 ETH

【op-node sequencer】（高级调试）
  RPC              http://${H}:${OP_NODE_RPC_PORT}

╔═══════════════════════════════════════════════════════════════════════╗
║              MetaMask / Rabby 添加自定义网络                            ║
╚═══════════════════════════════════════════════════════════════════════╝

  Network Name:   MAN Dev
  RPC URL:        http://${H}:${L2_RPC_PORT}
  Chain ID:       ${L2_CHAIN_ID}
  Currency:       ${NATIVE_TOKEN_SYMBOL}
  Explorer URL:   ${EXPLORER_URL}

╔═══════════════════════════════════════════════════════════════════════╗
║              要给团队成员发钱（dev ${NATIVE_TOKEN_SYMBOL}）                                ║
╚═══════════════════════════════════════════════════════════════════════╝

  Deployer EOA 在创世已经持有大量 ${NATIVE_TOKEN_SYMBOL}：
    地址  ${DEPLOYER_ADDRESS}
    私钥  ${DEPLOYER_PRIVATE_KEY}  ⚠️ 仅 dev！

  快捷给地址发钱（推荐）：
    make fund TO=0x... AMOUNT=100      # 转 100 ${NATIVE_TOKEN_SYMBOL}

  或手动用 cast（容器内执行）：
    docker run --rm --network mychain-dev --entrypoint cast ${ANVIL_IMAGE} \\
      send --private-key ${DEPLOYER_PRIVATE_KEY} \\
      <收款地址> --value 100ether \\
      --rpc-url http://op-geth:8545

╔═══════════════════════════════════════════════════════════════════════╗
║              ⚠️  AWS 安全组必须开的端口                                  ║
╚═══════════════════════════════════════════════════════════════════════╝

EOF

if [[ "$EXPLORER_MODE" == "reverse-proxy" ]]; then
cat <<EOF
  对外（团队 / 浏览器）：
    TCP 443           HTTPS — 浏览器入口（${BLOCKSCOUT_PUBLIC_URL}）
    TCP 80            HTTP → 443 重定向
    TCP ${L2_RPC_PORT}          op-geth HTTP RPC — 钱包 / cast / 合约部署
    TCP ${L2_WS_PORT}          op-geth WebSocket — 钱包 / dApp 监听
    TCP 22            SSH — 仅运维

  仅本机（不必对外，nginx 反代用 / 调试用）：
    TCP ${BLOCKSCOUT_PORT}          Blockscout frontend (loopback)
    TCP ${BLOCKSCOUT_API_PORT}          Blockscout backend  (loopback)
    TCP ${BLOCKSCOUT_STATS_PORT}          Blockscout stats    (loopback；浏览器需可达，反代到子域名后这里可关)
    TCP ${ANVIL_PORT}          L1 anvil — 真要外部访问就再开
    TCP ${OP_NODE_RPC_PORT}          op-node RPC — 真要外部调试就再开
EOF
else
cat <<EOF
  对外（团队 / 浏览器）：
    TCP ${L2_RPC_PORT}          op-geth HTTP RPC — 钱包 / cast / 合约部署
    TCP ${L2_WS_PORT}          op-geth WebSocket — 钱包 / dApp 监听
    TCP ${BLOCKSCOUT_PORT}          Blockscout frontend — 浏览器
    TCP ${BLOCKSCOUT_API_PORT}          Blockscout backend  — 前端 ajax 必须能直连
    TCP ${BLOCKSCOUT_STATS_PORT}          Blockscout stats    — 首页 Daily transactions / Charts 必须能直连
    TCP 22            SSH — 仅运维

  按需（默认不开）：
    TCP ${ANVIL_PORT}          L1 anvil — dev 调试用
    TCP ${OP_NODE_RPC_PORT}          op-node RPC — 高级调试用
EOF
fi

cat <<EOF

╔═══════════════════════════════════════════════════════════════════════╗
║              运维自检（只给运维看，不发同事）                            ║
╚═══════════════════════════════════════════════════════════════════════╝

  L2 区块号：    curl -s http://${H}:${L2_RPC_PORT} -H 'Content-Type: application/json' \\
                   -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
  Explorer：     curl -s '${EXPLORER_HEALTH_URL}' | jq '.items[0] | {height, hash, timestamp}'
  容器状态：     make status        # 主链
                 make blockscout-status

EOF
