#!/usr/bin/env bash
# =============================================================================
# 长期稳定性测试 —— 一屏运行总览
#
# 显示：
#   - spammer 容器状态 + uptime
#   - spammer 累计 ok / fail / fail{full=,nonce=,other=}
#   - 链上最近 N 块真实 TPS
#   - mempool 大小 (pending / queued)
#   - 链 head 块号
# =============================================================================

set -uo pipefail

cd "$(dirname "$0")/.."

ANVIL_IMG="ghcr.io/foundry-rs/foundry:stable"
RPC="http://op-geth:8545"
N_BLOCKS=${N_BLOCKS:-20}

# -----------------------------------------------------------------------------
# 1. spammer 容器状态
# -----------------------------------------------------------------------------
printf "\n📦 spammer 容器\n"
printf "%s\n" "----------------------------------------------------------------"
SPAMMER_INFO=$(docker ps -a --filter name=mychain-tokenspammer \
  --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}' 2>/dev/null)
if echo "$SPAMMER_INFO" | grep -q mychain-tokenspammer; then
  echo "$SPAMMER_INFO"
  RUNNING=$(docker inspect -f '{{.State.Running}}' mychain-tokenspammer 2>/dev/null || echo false)
else
  echo "  ⚠️  mychain-tokenspammer 容器不存在（make stability-up 启动）"
  RUNNING=false
fi

# 容器内的环境变量（确认 TARGET_TPS / BACKPRESSURE）
if [ "$RUNNING" = "true" ]; then
  TARGET_TPS=$(docker inspect mychain-tokenspammer --format \
    '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep -E '^TARGET_TPS=' | cut -d= -f2 | head -1)
  BP=$(docker inspect mychain-tokenspammer --format \
    '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep -E '^MEMPOOL_BACKPRESSURE=' | cut -d= -f2 | head -1)
  printf "  TARGET_TPS:   %s\n" "${TARGET_TPS:-default}"
  printf "  fail-fast:    %s\n" "$([ "${BP:-1}" = "0" ] && echo ON || echo OFF)"
fi

# -----------------------------------------------------------------------------
# 2. spammer 累计统计（拉最后 200 行日志找最新 report）
# -----------------------------------------------------------------------------
printf "\n📊 spammer 累计统计（最新 report 行）\n"
printf "%s\n" "----------------------------------------------------------------"
if [ "$RUNNING" = "true" ]; then
  # spammer 会周期打 "  spam | t=Xs ok=N fail=M ..." 之类的行
  # 取最后一行包含 ok= 和 fail= 的，输出原文（spammer 自己已格式化好）
  LAST_REPORT=$(docker logs --tail=300 mychain-tokenspammer 2>&1 \
    | grep -E 'ok=.*fail=' | tail -1 || true)
  if [ -n "$LAST_REPORT" ]; then
    echo "  $LAST_REPORT"
  else
    echo "  （还没有 report 行，spammer 刚启动？）"
  fi

  # 看是否有 unclassified error sample（v6 修复的 fail-fast keyword 兜底）
  UNCLAS=$(docker logs --tail=500 mychain-tokenspammer 2>&1 \
    | grep '\[DEBUG\] unclassified error sample' | tail -3 || true)
  if [ -n "$UNCLAS" ]; then
    printf "\n  ⚠️  未识别错误样本（spammer 已 sample 前 5 个）：\n"
    echo "$UNCLAS" | sed 's/^/    /'
  fi
else
  echo "  （容器未运行）"
fi

# -----------------------------------------------------------------------------
# 3. 链头部 + 最近 N 块 TPS
# -----------------------------------------------------------------------------
printf "\n⛓️  链上 TPS（最近 %d 块）\n" "$N_BLOCKS"
printf "%s\n" "----------------------------------------------------------------"
docker run --rm --network mychain-dev --entrypoint sh -e "RPC=$RPC" "$ANVIL_IMG" -c '
  set -e
  N='"$N_BLOCKS"'
  HEAD=$(cast block-number --rpc-url $RPC)
  TOTAL=0; FIRST_TS=0; LAST_TS=0
  i=$((N-1))
  while [ $i -ge 0 ]; do
    H=$((HEAD - i))
    HEX=$(printf "0x%x" $H)
    BLK=$(cast rpc eth_getBlockByNumber "$HEX" false --rpc-url $RPC)
    TX=$(echo "$BLK" | grep -oE "\"transactions\":\\[[^]]*\\]" | tr -d "\"\\[\\]" | tr "," "\n" | grep -c "0x" || echo 0)
    [ -z "$TX" ] && TX=0
    case "$TX" in *[!0-9]*) TX=0 ;; esac
    TS_HEX=$(echo "$BLK" | grep -oE "\"timestamp\":\"0x[0-9a-f]*\"" | grep -oE "0x[0-9a-f]*")
    TS=$(printf "%d" $TS_HEX)
    [ $FIRST_TS -eq 0 ] && FIRST_TS=$TS
    LAST_TS=$TS
    TOTAL=$((TOTAL + TX))
    i=$((i - 1))
  done
  SPAN=$((LAST_TS - FIRST_TS))
  printf "  head:        %d\n" "$HEAD"
  printf "  最近 %d 块:   共 %d tx  /  时间跨度 %ds\n" "$N" "$TOTAL" "$SPAN"
  if [ $SPAN -gt 0 ]; then
    printf "  实测 TPS:    %d  (= %d / %d)\n" "$((TOTAL / SPAN))" "$TOTAL" "$SPAN"
  else
    printf "  实测 TPS:    -- (时间跨度 0)\n"
  fi
' 2>/dev/null || echo "  （RPC 查询失败）"

# -----------------------------------------------------------------------------
# 4. mempool
# -----------------------------------------------------------------------------
printf "\n📥 mempool\n"
printf "%s\n" "----------------------------------------------------------------"
docker run --rm --network mychain-dev --entrypoint sh -e "RPC=$RPC" "$ANVIL_IMG" -c '
  RES=$(cast rpc txpool_status --rpc-url $RPC)
  PENDING=$(echo "$RES" | grep -oE "\"pending\":\"0x[0-9a-f]*\"" | grep -oE "0x[0-9a-f]*")
  QUEUED=$(echo "$RES"  | grep -oE "\"queued\":\"0x[0-9a-f]*\""  | grep -oE "0x[0-9a-f]*")
  P=$(printf "%d" $PENDING)
  Q=$(printf "%d" $QUEUED)
  echo "  pending: $P"
  echo "  queued : $Q"
  # 健康判断：fail-fast baseline globalslots=500，pending ≤ 800 算正常
  if [ $P -gt 1500 ]; then
    echo "  🚨 pending > 1500 — 链消化跟不上，可能 globalslots 配置过大或 spammer 过载"
  elif [ $P -gt 800 ]; then
    echo "  ⚠️  pending > 800 — fail-fast 边缘"
  fi
' 2>/dev/null || echo "  （RPC 查询失败）"

# -----------------------------------------------------------------------------
# 5. 简短建议
# -----------------------------------------------------------------------------
cat <<'EOF'

----------------------------------------------------------------
🔍 详细诊断:   make bot-token-diag
📜 实时日志:   make stability-logs
🛑 停止测试:   make stability-down
EOF
