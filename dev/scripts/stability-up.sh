#!/usr/bin/env bash
# =============================================================================
# 长期稳定性测试启动器
#
# 自动准备：1000 ERC-20 + 50000 钱包 + gas 注资 + token seed
# 然后启动 daemon spam，每秒 N 笔随机互转，直到 stability-down 才停。
#
# 设计原则：完全幂等
#   - 第一次跑：从 0 一路准备到启动 spam（~10-15 分钟）
#   - 之后跑：检测到所有资源就绪，秒启 spam daemon
#   - stability-down 后再 stability-up：只需 ~10s
#
# 默认参数：
#   TARGET_TPS=150          一期 SLA（链稳态 ~180 的 0.83x，留 buffer）
#   MEMPOOL_BACKPRESSURE=0  fail-fast 模式（链层超载即时拒绝，配合 globalslots=500）
#
# 用法：
#   make stability-up                       # 默认 150 TPS
#   TARGET_TPS=100 make stability-up        # 自定义 TPS
#   make stability-down                     # 停 spam，保留所有数据
#   make stability-status                   # 一屏总览
#   make stability-logs                     # tail spammer 日志
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."   # 切到 dev/

TARGET_TPS=${TARGET_TPS:-150}
BACKPRESSURE=${MEMPOOL_BACKPRESSURE:-0}
# deployer 余额下限（基础预留，fund-gas/seed 等大额支出走自动重试 mint）
DEPLOYER_BAL_FLOOR=${DEPLOYER_BAL_FLOOR:-100}
# 一次性 mint 的 MAN 数：30000 = fund-gas 25000 + seed 35 + 余量
# 已经 fund 过的二次启动会被 cmdFundGas 跳过，不触发 mint
MINT_AMOUNT_INIT=${MINT_AMOUNT_INIT:-30000}
# 余额下限触发的小额 mint（dev 阶段防 deployer 接近 0 的边缘场景）
MINT_AMOUNT_TOPUP=${MINT_AMOUNT_TOPUP:-500}

# .env 里的 deployer 地址（用 cast 直查余额）
DEPLOYER=$(grep '^DEPLOYER_ADDRESS=' .env 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r"' || true)
if [ -z "$DEPLOYER" ]; then
  echo "❌ .env 里没有 DEPLOYER_ADDRESS，跑 make dev-up 先把链拉起来"
  exit 1
fi

ANVIL_IMG="ghcr.io/foundry-rs/foundry:stable"
RPC="http://op-geth:8545"

banner() { printf "\n==================== %s ====================\n" "$1"; }

# -----------------------------------------------------------------------------
# Step 1：链健康 + fail-fast 配置确认
# -----------------------------------------------------------------------------
banner "1. 链健康 + fail-fast 配置"

if ! docker ps --format '{{.Names}}' | grep -qx mychain-op-geth; then
  echo "❌ mychain-op-geth 没在跑。先：cd dev && make dev-up"
  exit 1
fi
echo "  ✓ mychain-op-geth running"

# 看 op-geth 实际拿到的 globalslots（验证 fail-fast 配置生效）
GLOBAL_SLOTS=$(docker inspect mychain-op-geth --format '{{range .Args}}{{println .}}{{end}}' \
  | grep -oE 'txpool.globalslots=[0-9]+' | cut -d= -f2 | head -1)
GLOBAL_SLOTS=${GLOBAL_SLOTS:-unknown}
echo "  当前 op-geth --txpool.globalslots=$GLOBAL_SLOTS"

if [ "$GLOBAL_SLOTS" = "unknown" ]; then
  echo "  ⚠️  无法读到 globalslots，配置异常"
elif [ "$GLOBAL_SLOTS" -le 1000 ]; then
  echo "  ✓ fail-fast 模式生效（globalslots ≤ 1000）"
else
  cat <<EOF
  ⚠️  容量模式（globalslots=$GLOBAL_SLOTS），稳定性测试推荐 fail-fast
      .env 里设置：
          OP_GETH_TXPOOL_GLOBALSLOTS=500
          OP_GETH_TXPOOL_GLOBALQUEUE=200
          OP_GETH_TXPOOL_ACCOUNTSLOTS=8
          OP_GETH_TXPOOL_ACCOUNTQUEUE=16
      然后：
          docker compose up -d --force-recreate op-geth
      （想继续用容量模式 5 秒后自动继续）
EOF
  sleep 5
fi

# 出块速度健康检查
HEAD1=$(docker run --rm --network mychain-dev --entrypoint sh "$ANVIL_IMG" \
  -c "cast block-number --rpc-url $RPC" 2>/dev/null | tail -1 | tr -d '\r')
sleep 3
HEAD2=$(docker run --rm --network mychain-dev --entrypoint sh "$ANVIL_IMG" \
  -c "cast block-number --rpc-url $RPC" 2>/dev/null | tail -1 | tr -d '\r')
DELTA=$((HEAD2 - HEAD1))
if [ "$DELTA" -lt 1 ]; then
  echo "❌ 3 秒内只出 $DELTA 块（HEAD $HEAD1 -> $HEAD2），链 stuck"
  exit 1
fi
echo "  ✓ 出块正常 (3s 内 +$DELTA 块, head=$HEAD2)"

# -----------------------------------------------------------------------------
# Step 2：npm 依赖（首次 ~30s，之后秒过）
# -----------------------------------------------------------------------------
banner "2. tokenspammer npm 依赖"
if [ -d bots/tokenspammer/node_modules ]; then
  echo "  ✓ node_modules 已存在"
else
  echo "  装 npm 依赖..."
  make bot-token-install
fi

# -----------------------------------------------------------------------------
# Step 3：合约 artifacts（首次 ~10s，之后秒过）
# -----------------------------------------------------------------------------
banner "3. 合约 artifacts (BatchTransfer + TestERC20)"
if [ -f bots/tokenspammer/artifacts.json ]; then
  echo "  ✓ artifacts.json 已存在"
else
  echo "  forge 编译..."
  make bot-token-build
fi

# -----------------------------------------------------------------------------
# Step 4：50000 钱包（首次 ~30s，之后秒过；cmdInit 自检数量幂等）
# -----------------------------------------------------------------------------
banner "4. 50000 钱包 (wallets-50k.json)"
make bot-token-init

# -----------------------------------------------------------------------------
# Step 5：deployer 余额（不足就 mint）
# -----------------------------------------------------------------------------
banner "5. deployer 余额检查"
BAL_MAN=$(docker run --rm --network mychain-dev --entrypoint sh "$ANVIL_IMG" \
  -c "cast balance $DEPLOYER --rpc-url $RPC -e 2>/dev/null" \
  | tail -1 | tr -d '\r' | xargs)
BAL_INT=${BAL_MAN%%.*}
[ -z "$BAL_INT" ] && BAL_INT=0

echo "  deployer:    $DEPLOYER"
echo "  余额:        $BAL_MAN MAN"
echo "  目标下限:    $DEPLOYER_BAL_FLOOR MAN"

if [ "$BAL_INT" -lt "$DEPLOYER_BAL_FLOOR" ]; then
  echo "  ⚠️  余额低于下限 $DEPLOYER_BAL_FLOOR MAN，topup mint $MINT_AMOUNT_TOPUP MAN..."
  make bot-token-mint AMOUNT="$MINT_AMOUNT_TOPUP"
else
  echo "  ✓ 余额满足基础预留（≥ $DEPLOYER_BAL_FLOOR MAN）"
  echo "  注意：fund-gas（首次需 ~25000 MAN）、seed（首次需 ~35 MAN）"
  echo "        若失败将自动 mint $MINT_AMOUNT_INIT MAN 后重试"
fi

# -----------------------------------------------------------------------------
# Step 6：1000 token 部署（cmdDeploy 自检 tokens.length 幂等；首次 ~3-5 分钟）
# -----------------------------------------------------------------------------
banner "6. 1000 ERC-20 部署 + BatchTransfer"
make bot-token-deploy

# -----------------------------------------------------------------------------
# Step 7：50k 钱包 gas 注资
#   首次：~25000 MAN 大额，cmdFundGas 检查余额不足会 fail；脚本自动 mint 重试
#   二次：cmdFundGas 抽样发现钱包已 fund，瞬间跳过，不触发 mint（不浪费 NAL 池）
#   首次耗时 ~5-10 分钟，二次 ~5 秒
# -----------------------------------------------------------------------------
banner "7. 50000 钱包 gas 注资"
if ! make bot-token-fund-gas; then
  echo ""
  echo "  ⚠️  fund-gas 失败（多半是 deployer 余额不够 25000+ MAN）"
  echo "  自动 mint $MINT_AMOUNT_INIT MAN 后重试..."
  echo ""
  make bot-token-mint AMOUNT="$MINT_AMOUNT_INIT"
  echo ""
  echo "  重试 fund-gas..."
  make bot-token-fund-gas   # 重试再失败将由 set -e 直接退出
fi

# -----------------------------------------------------------------------------
# Step 8：token seed → 每 token 500 个 holder
#   首次：~35 MAN，cmdSeed 检查覆盖率不足会跑；fail 时自动 mint 重试
#   二次：所有 token 已 seed → 立即跳过
#   首次耗时 ~10 分钟，二次 ~5 秒
# -----------------------------------------------------------------------------
banner "8. token seed (每 token 500 holder)"
if ! make bot-token-seed; then
  echo ""
  echo "  ⚠️  seed 失败（可能 deployer 余额不够 ~35 MAN）"
  echo "  自动 mint $MINT_AMOUNT_TOPUP MAN 后重试..."
  echo ""
  make bot-token-mint AMOUNT="$MINT_AMOUNT_TOPUP"
  echo ""
  echo "  重试 seed..."
  make bot-token-seed
fi

# -----------------------------------------------------------------------------
# Step 9：启动 daemon spammer
# -----------------------------------------------------------------------------
banner "9. 启动 daemon spammer"
TARGET_TPS="$TARGET_TPS" MEMPOOL_BACKPRESSURE="$BACKPRESSURE" \
  make bot-token-spam-up

# -----------------------------------------------------------------------------
# 总结
# -----------------------------------------------------------------------------
cat <<EOF

============================================
✅ 长期稳定性测试已启动
============================================
  目标 TPS:     $TARGET_TPS  (一期 SLA)
  fail-fast:    $([ "$BACKPRESSURE" = "0" ] && echo "ON  (链层超载即时拒绝)" || echo "OFF (软背压排队)")
  globalslots:  $GLOBAL_SLOTS
  容器:         mychain-tokenspammer  (restart unless-stopped)
  数据:         50000 钱包 × 1000 token (每 token 500 holder)
============================================

监控 (随时跑)：
  make stability-status        一屏总览（链 TPS / mempool / spammer 累计）
  make stability-logs          tail spammer 实时日志
  make bot-token-chain-tps N=20    链上最近 20 块的真实 TPS
  make bot-token-mempool           mempool 大小 (pending/queued)
  make bot-token-diag              全量诊断（spam 跑着的时候用）

停止 (保留所有数据，下次秒启)：
  make stability-down

后台运行说明：
  即使关闭终端 / 服务器重启，daemon 会自动 restart，spam 持续。
  数据持久在 dev/bots/tokenspammer/{wallets-50k,tokens,artifacts}.json
EOF
