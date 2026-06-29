#!/usr/bin/env bash
# =============================================================================
# flashblocks-monitor.sh — v7 stack 长跑期间的指标采样器
#
# 跑法（跟 stress-soak.sh 并行跑）：
#   终端 1：make bot-token-soak TARGET_TPS=500 DURATION=600   # v7 mode 自动走 bundle-proxy
#   终端 2：bash dev/scripts/flashblocks-monitor.sh 600       # 监控 600s
#
# 每 5s 采一次，写 CSV + 实时打印。最后输出 summary。
#
# 采样字段：
#   ts            时间戳
#   inflight      bundle-proxy 当前 in-flight 请求数
#   saturation    inflight / IN_FLIGHT_LIMIT
#   circuit       熔断器状态（closed/half_open/open）
#   rpc_ok        eth_sendRawTransaction outcome=ok 累计
#   rpc_rejected  outcome=rejected 累计（fail-fast 命中）
#   fallback      fallback_total 累计
#   head_stale_ms head tracker 上次刷新距今
#   reorg_count   Blockscout backend 日志里 non_canonical 累计
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."

set -a
[[ -f .env ]] && source .env
[[ -f .env.flashblocks ]] && source .env.flashblocks
set +a

: "${BUNDLE_PROXY_METRICS_PORT:=9561}"
: "${BUNDLE_PROXY_IN_FLIGHT_LIMIT:=1000}"

H="${PUBLIC_HOST:-127.0.0.1}"
METRICS="http://${H}:${BUNDLE_PROXY_METRICS_PORT}/metrics"
PROXY="http://${H}:${BUNDLE_PROXY_PORT:-9560}"

DURATION=${1:-600}
INTERVAL=${INTERVAL:-5}

OUT_DIR=${OUT_DIR:-flashblocks-monitor-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT_DIR"
CSV="$OUT_DIR/samples.csv"
LOG="$OUT_DIR/monitor.log"

exec > >(tee -a "$LOG") 2>&1

echo "============================================"
echo "📊 v7 stack 长跑指标监控"
echo "  metrics    : $METRICS"
echo "  duration   : ${DURATION}s, interval ${INTERVAL}s"
echo "  in-flight  : limit=$BUNDLE_PROXY_IN_FLIGHT_LIMIT"
echo "  output     : $OUT_DIR/"
echo "============================================"

# CSV header
echo "ts,inflight,saturation,circuit,rpc_ok,rpc_rejected,rpc_fallback_ok,rpc_rbuilder_failed,fallback_total,head_stale_ms,reorg_count" > "$CSV"

# 提取 prom counter（单标签）
m_counter() {
  local name=$1
  local pat=$2
  curl -s --max-time 3 "$METRICS" | grep -E "^${name}\{${pat}\}" | awk '{print $2}' | head -1 | sed 's/[^0-9.]//g'
}

# 提取 prom gauge
m_gauge() {
  local name=$1
  curl -s --max-time 3 "$METRICS" | grep -E "^${name} " | awk '{print $2}' | head -1 | sed 's/[^0-9.]//g'
}

# Blockscout reorg 计数（依赖 backend 容器日志）
reorg_count() {
  docker logs --since=2s mychain-blockscout-backend 2>&1 | grep -ci "non_canonical\|reorg" || echo 0
}

CIRCUIT_LABEL=("closed" "half_open" "open")

start_ts=$(date +%s)
prev_ok=0
prev_rej=0
prev_fb=0
prev_rebuilder_fail=0
total_reorg=0

printf "%-19s %-10s %-6s %-10s %-7s %-7s %-7s %-6s %-9s %-7s\n" \
  "ts" "inflight" "sat" "circuit" "ok" "rej" "fb_ok" "rbf" "head_stale" "reorg/s"
printf "%-19s %-10s %-6s %-10s %-7s %-7s %-7s %-6s %-9s %-7s\n" \
  "-------------------" "--------" "----" "--------" "------" "------" "------" "----" "---------" "------"

while true; do
  now=$(date +%s)
  if (( now - start_ts >= DURATION )); then
    break
  fi

  ts=$(date '+%Y-%m-%d %H:%M:%S')

  inflight=$(m_gauge "bundle_proxy_inflight" || echo 0)
  inflight=${inflight:-0}
  saturation=$(python3 -c "print(f'{${inflight:-0}/${BUNDLE_PROXY_IN_FLIGHT_LIMIT}:.2f}')" 2>/dev/null || echo "?")

  circuit_n=$(m_gauge "bundle_proxy_circuit_state" || echo 0)
  circuit_n=${circuit_n:-0}
  circuit=${CIRCUIT_LABEL[${circuit_n%.*}]:-unknown}

  ok=$(m_counter "bundle_proxy_rpc_total" 'method="eth_sendRawTransaction",outcome="ok"' || echo 0)
  ok=${ok:-0}
  rej=$(m_counter "bundle_proxy_rpc_total" 'method="eth_sendRawTransaction",outcome="rejected"' || echo 0)
  rej=${rej:-0}
  fb_ok=$(m_counter "bundle_proxy_rpc_total" 'method="eth_sendRawTransaction",outcome="rbuilder_fail_fallback_ok"' || echo 0)
  fb_ok=${fb_ok:-0}
  rbf=$(m_counter "bundle_proxy_rpc_total" 'method="eth_sendRawTransaction",outcome="rbuilder_failed"' || echo 0)
  rbf=${rbf:-0}

  fb_total=$(m_counter "bundle_proxy_fallback_total" '' || echo 0)
  fb_total=$(curl -s --max-time 3 "$METRICS" | grep -E "^bundle_proxy_fallback_total " | awk '{print $2}' | head -1 | sed 's/[^0-9.]//g')
  fb_total=${fb_total:-0}

  head_stale=$(m_gauge "bundle_proxy_head_stale_ms" || echo 0)
  head_stale=${head_stale:-0}
  head_stale=${head_stale%.*}

  reorg_per_interval=$(reorg_count)
  total_reorg=$((total_reorg + reorg_per_interval))

  printf "%-19s %-10s %-6s %-10s %-7s %-7s %-7s %-6s %-9s %-7s\n" \
    "$ts" "${inflight%.*}" "$saturation" "$circuit" "${ok%.*}" "${rej%.*}" "${fb_ok%.*}" "${rbf%.*}" "$head_stale" "$reorg_per_interval"

  echo "$ts,${inflight%.*},$saturation,$circuit,${ok%.*},${rej%.*},${fb_ok%.*},${rbf%.*},${fb_total%.*},$head_stale,$reorg_per_interval" >> "$CSV"

  sleep $INTERVAL
done

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================"
echo "📊 监控结束 — summary"
echo "============================================"

# 用 awk 算 CSV 后 80% 的稳态指标（去掉 warmup 期）
total_rows=$(wc -l < "$CSV")
skip_rows=$((total_rows / 5))
echo ""
echo "📈 稳态期统计（跳过前 20% warmup，剩余 $((total_rows - skip_rows - 1)) 个采样点）"
echo ""

awk -F, -v skip="$skip_rows" '
NR == 1 { next }
NR > skip+1 {
  inflight_sum += $2;
  sat_sum += $3;
  if ($2 > inflight_max) inflight_max = $2;
  if ($3 > sat_max) sat_max = $3;
  count++;
}
END {
  if (count > 0) {
    printf "  in-flight  : avg=%.1f, max=%.1f\n", inflight_sum/count, inflight_max;
    printf "  saturation : avg=%.2f, max=%.2f\n", sat_sum/count, sat_max;
  }
}' "$CSV"

# 最终值（最后一行）
last_line=$(tail -1 "$CSV")
IFS=',' read -r ts inflight sat circuit ok rej fb_ok rbf fb_total head_stale reorg <<< "$last_line"
echo ""
echo "  最终累计计数器："
echo "  rpc_total{ok}            : $ok"
echo "  rpc_total{rejected}      : $rej   ← fail-fast 命中次数"
echo "  rpc_total{rbuilder_fail_fallback_ok} : $fb_ok   ← fallback 救回次数"
echo "  rpc_total{rbuilder_failed}: $rbf"
echo "  fallback_total           : $fb_total"
echo "  total reorg in window    : $total_reorg   ← D3=force_d3b 风险量化"
echo ""
echo "  最终熔断器状态           : $circuit（预期 closed）"
echo "  最终 head_stale_ms       : $head_stale ms（预期 < 1000ms）"
echo ""
echo "📁 详细数据 : $OUT_DIR/"
echo "   samples.csv  — 全量采样"
echo "   monitor.log  — 本次输出"
echo ""
echo "下一步：把 $CSV 贴进 docs/STRESS_TEST_REPORT_V7.md §3 v7 实测数据"
