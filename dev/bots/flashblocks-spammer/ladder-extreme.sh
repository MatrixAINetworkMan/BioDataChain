#!/usr/bin/env bash
# =============================================================================
# Phase 1.5 极限 ladder：找 Flashblocks 在当前硬件 + 当前 spammer 下的真拐点
#
# 阶梯：800 / 1000 / 1500 / 2000 / 2500 TPS
# 每档 30s spam + 15s drain（DRAIN_S 让 inclusion 接近 100%）
# HTTP_POOL_SIZE 同步从 32 → 192 递增（避免连接池被 1500+ TPS 打爆）
# 档间间隔 15s 给 Node.js GC + 链上 settle
#
# 输出：logs/ladder-extreme-<时间戳>/
#   ├── 800.log / 1000.log / 1500.log / 2000.log / 2500.log
#   └── summary.txt   汇总各档 user TPS / err rate / inclusion / RPC lat
#
# 用法：bash ladder-extreme.sh
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")"

DURATION_S="${DURATION_S:-30}"
DRAIN_S="${DRAIN_S:-15}"
COOLDOWN_S="${COOLDOWN_S:-15}"
ERR_SAMPLES_MAX="${ERR_SAMPLES_MAX:-20}"

# 阶梯配置：tps : senders : pool_size : pipelining
# senders 取 tps/4（每个 sender 4 笔/s，模拟低单点压力）
LADDER=(
  "800:200:32:10"
  "1000:250:32:10"
  "1500:375:64:12"
  "2000:500:96:14"
  "2500:625:128:16"
)

TS=$(date +%Y%m%d-%H%M%S)
DIR="logs/ladder-extreme-$TS"
mkdir -p "$DIR"

echo "==========================================="
echo "  Phase 1.5 极限 ladder ($TS)"
echo "  ${#LADDER[@]} 档：$(echo "${LADDER[@]}" | tr ' ' '\n' | awk -F: '{print $1}' | tr '\n' ' ')"
echo "  per step: ${DURATION_S}s spam + ${DRAIN_S}s drain + ${COOLDOWN_S}s cooldown"
echo "  output: $DIR/"
echo "==========================================="

if [[ ! -d node_modules ]]; then
  echo ""
  echo "=== 装依赖（一次性）==="
  docker run --rm -v "$(pwd)":/app -w /app node:20-alpine npm install
fi

SUMMARY="$DIR/summary.txt"
{
  echo "Phase 1.5 ladder summary  ($TS)"
  echo ""
  printf "%-8s %-8s %-8s %-12s %-12s %-12s %-12s %-12s %-12s\n" \
    "TPS" "senders" "pool" "sent" "ok" "err%" "userTPS" "incl%" "p50ms"
  echo "-------------------------------------------------------------------------------------------------"
} > "$SUMMARY"

run_step() {
  local tps=$1 senders=$2 pool=$3 pipe=$4
  local logfile="$DIR/${tps}.log"

  echo ""
  echo "==========================================="
  echo "  STEP: TPS=$tps senders=$senders pool=$pool pipe=$pipe"
  echo "==========================================="

  docker rm -f fb-spam-step 2>/dev/null > /dev/null
  docker run --rm --network host -v "$(pwd)":/app -w /app \
    -e TARGET_TPS="$tps" \
    -e N_SENDERS="$senders" \
    -e DURATION_S="$DURATION_S" \
    -e DRAIN_S="$DRAIN_S" \
    -e HTTP_POOL_SIZE="$pool" \
    -e HTTP_PIPELINE="$pipe" \
    -e ERR_SAMPLES_MAX="$ERR_SAMPLES_MAX" \
    --name fb-spam-step \
    node:20-alpine \
    node spammer.js 2>&1 | tee "$logfile"

  # 提取关键指标写到 summary
  local sent ok errpct utps inclpct p50
  sent=$(grep -E "^bundles sent:" "$logfile" | awk '{print $3}' | tail -1)
  ok=$(grep -E "^bundles ok:" "$logfile" | awk '{print $3}' | tail -1)
  errpct=$(grep -E "^error rate:" "$logfile" | awk '{print $3}' | tr -d '%' | tail -1)
  utps=$(grep "approx user  TPS:" "$logfile" | awk -F'TPS:' '{print $2}' | tr -d ' ' | tail -1)
  inclpct=$(grep "^inclusion rate:" "$logfile" | awk '{print $3}' | tr -d '%' | tail -1)
  p50=$(grep "^rpc lat" "$logfile" | sed -E 's/.*p50=([0-9]+).*/\1/' | tail -1)

  printf "%-8s %-8s %-8s %-12s %-12s %-12s %-12s %-12s %-12s\n" \
    "$tps" "$senders" "$pool" "${sent:-?}" "${ok:-?}" "${errpct:-?}" "${utps:-?}" "${inclpct:-?}" "${p50:-?}" \
    >> "$SUMMARY"

  echo ""
  echo "[step done] tps=$tps  user TPS=${utps:-?}  err=${errpct:-?}%  incl=${inclpct:-?}%"
  echo "  cooling down ${COOLDOWN_S}s..."
  sleep "$COOLDOWN_S"
}

for entry in "${LADDER[@]}"; do
  IFS=: read -r tps senders pool pipe <<< "$entry"
  run_step "$tps" "$senders" "$pool" "$pipe"
done

echo ""
echo "==========================================="
echo "  ladder 完成。汇总："
echo "==========================================="
cat "$SUMMARY"
echo ""
echo "  详情见 $DIR/{800,1000,1500,2000,2500}.log"
