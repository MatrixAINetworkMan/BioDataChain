#!/usr/bin/env bash
# Phase 1.3 阶梯压测：100 / 300 / 500 / 1000 TPS 各跑 60s，找 builder-playground +
# Flashblocks 的 TPS 拐点。
#
# 用法：
#   bash ladder.sh                                   # 默认 4 档
#   STEPS="200 400 600 800" DURATION_S=120 bash ladder.sh   # 自定义
#
# 依赖：宿主机有 docker（自动 pull node:20-alpine + viem）。
# 运行环境：chain-test2 / builder-playground 已经起好（playground start opstack）

set -euo pipefail

cd "$(dirname "$0")"

STEPS="${STEPS:-100 300 500 1000}"
DURATION_S="${DURATION_S:-60}"
RPC_URL="${RPC_URL:-http://127.0.0.1:8547}"           # op-rbuilder
READ_RPC_URL="${READ_RPC_URL:-http://127.0.0.1:8548}" # flashblocks-rpc
SLEEP_BETWEEN="${SLEEP_BETWEEN:-15}"

# senders 数：按 TPS / 4 估（保证每个 sender 平均 4 笔/s 不会 nonce drift）
calc_senders() {
  local tps=$1
  echo $(( (tps + 3) / 4 ))
}

# 准备 node_modules（一次性）
if [[ ! -d node_modules ]]; then
  echo "=== 一次性装 npm 依赖（写入宿主机 node_modules）==="
  docker run --rm -v "$(pwd)":/app -w /app node:20-alpine npm install
fi

mkdir -p logs
TS=$(date +%Y%m%d-%H%M%S)
LOG_DIR="logs/ladder-$TS"
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/summary.txt"

echo "=== ladder run $TS ===" | tee "$SUMMARY"
echo "  steps:        $STEPS" | tee -a "$SUMMARY"
echo "  duration_s:   $DURATION_S" | tee -a "$SUMMARY"
echo "  rpc:          $RPC_URL" | tee -a "$SUMMARY"
echo "  read_rpc:     $READ_RPC_URL" | tee -a "$SUMMARY"
echo "  sleep_between:$SLEEP_BETWEEN" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"

for tps in $STEPS; do
  n_senders=$(calc_senders "$tps")
  log="$LOG_DIR/tps-${tps}.log"

  echo "###########################################" | tee -a "$SUMMARY"
  echo "#   TARGET_TPS=$tps   N_SENDERS=$n_senders" | tee -a "$SUMMARY"
  echo "###########################################" | tee -a "$SUMMARY"

  docker run --rm \
    --network host \
    -v "$(pwd)":/app \
    -w /app \
    -e RPC_URL="$RPC_URL" \
    -e READ_RPC_URL="$READ_RPC_URL" \
    -e TARGET_TPS="$tps" \
    -e N_SENDERS="$n_senders" \
    -e DURATION_S="$DURATION_S" \
    node:20-alpine \
    node spammer.js 2>&1 | tee "$log"

  # 提取 final report 的几个关键指标加进 summary
  {
    echo ""
    echo "  -- final --"
    grep -E "bundles (sent|ok|err):|error rate:|approx (chain|user) TPS:|max txs in single block:|rpc lat \(ms\):" "$log" | sed 's/^/  /'
    echo ""
  } | tee -a "$SUMMARY"

  echo "  ↑ done $tps TPS, sleeping $SLEEP_BETWEEN s before next..." | tee -a "$SUMMARY"
  sleep "$SLEEP_BETWEEN"
done

echo "" | tee -a "$SUMMARY"
echo "=== 全部完成 ===" | tee -a "$SUMMARY"
echo "logs: $LOG_DIR/" | tee -a "$SUMMARY"
echo "summary: $SUMMARY"
