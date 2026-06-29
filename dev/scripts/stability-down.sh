#!/usr/bin/env bash
# =============================================================================
# 停止长期稳定性测试
#
# 只 stop spammer 容器，保留：
#   - wallets-50k.json    50000 钱包私钥
#   - tokens.json         1000 token + holder 列表
#   - artifacts.json      合约编译产物
#   - mempool 里没消化完的 tx（链层自然排队消化）
#
# 下次跑 make stability-up：检测到所有资源就绪，~10s 重新启动 spam。
#
# 想真正归零数据：make bot-token-clean
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> 停 spammer daemon..."
docker rm -f mychain-tokenspammer >/dev/null 2>&1 || true
echo "  ✓ mychain-tokenspammer 已停"

echo ""
echo "==> 当前 mempool 状态（链会自己消化完）："
RPC="http://op-geth:8545"
ANVIL_IMG="ghcr.io/foundry-rs/foundry:stable"
docker run --rm --network mychain-dev --entrypoint sh "$ANVIL_IMG" -c "
  set -e
  RES=\$(cast rpc txpool_status --rpc-url $RPC 2>/dev/null || echo '{}')
  PENDING=\$(echo \"\$RES\" | grep -oE '\"pending\":\"0x[0-9a-f]*\"' | grep -oE '0x[0-9a-f]*' || echo 0x0)
  QUEUED=\$(echo \"\$RES\"  | grep -oE '\"queued\":\"0x[0-9a-f]*\"'  | grep -oE '0x[0-9a-f]*' || echo 0x0)
  printf '  pending: %d\n' \$PENDING
  printf '  queued : %d\n' \$QUEUED
" 2>/dev/null || echo "  （查询失败，跳过）"

cat <<'EOF'

============================================
✅ 稳定性测试已停止（数据保留）
============================================
  下次启动:   make stability-up        （秒级，跳过初始化）
  彻底归零:   make bot-token-clean     （清 wallets / tokens / artifacts）
EOF
