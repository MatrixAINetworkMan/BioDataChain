#!/usr/bin/env bash
# =============================================================================
# flashblocks-chaos.sh — v7 故障注入测试
#
# 验证 bundle-proxy 在 4 种异常下的行为是否符合 PHASE2_INTEGRATION.md §7 表格：
#
#   1. rbuilder-down       op-rbuilder 停 30s，预期 bundle-proxy fallback → op-geth
#   2. proxy-overload      并发 IN_FLIGHT_LIMIT × 1.5 笔，预期触发 -32000 fail-fast
#   3. flashblocks-rpc-down  停 flashblocks-rpc 30s，预期读路径 fallback 到 op-geth
#   4. rollup-boost-down   停 rollup-boost 5s 看 op-node 行为（critical，链会停）
#
# 跑法：bash dev/scripts/flashblocks-chaos.sh [scenario]
#   - 不带参数：跑全部 4 个场景
#   - 带参数：跑指定一个，例如 bash flashblocks-chaos.sh rbuilder-down
#
# 前置：v7 stack Up（make dev-up-flashblocks），且 tokenspammer / spammer 没在跑
#       （混着跑可能干扰故障注入的并发数）
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."

set -a
[[ -f .env ]] && source .env
[[ -f .env.flashblocks ]] && source .env.flashblocks
set +a

: "${BUNDLE_PROXY_PORT:=9560}"
: "${BUNDLE_PROXY_METRICS_PORT:=9561}"
: "${BUNDLE_PROXY_IN_FLIGHT_LIMIT:=1000}"

H="${PUBLIC_HOST:-127.0.0.1}"
PROXY="http://${H}:${BUNDLE_PROXY_PORT}"
METRICS="http://${H}:${BUNDLE_PROXY_METRICS_PORT}/metrics"

SCENARIO="${1:-all}"

echo "============================================"
echo "🌪️  v7 Flashblocks 故障注入"
echo "  proxy           : $PROXY"
echo "  in-flight limit : $BUNDLE_PROXY_IN_FLIGHT_LIMIT"
echo "  scenario        : $SCENARIO"
echo "============================================"

# 一笔合法但极可能 nonce 错误的 raw tx（要的是触发上游处理流程，不要求上链成功）
DUMMY_TX='0x02f87282abcd0184773594008477359400825208940000000000000000000000000000000000000000880de0b6b3a764000080c001a0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

rpc_send_raw() {
  curl -s --max-time 5 "$PROXY" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendRawTransaction\",\"params\":[\"$DUMMY_TX\"],\"id\":$(date +%s%N)}"
}

metric() {
  curl -s --max-time 3 "$METRICS" | grep -E "^bundle_proxy_${1}" | head -5
}

# =============================================================================
# 场景 1: rbuilder-down 30s
# =============================================================================
chaos_rbuilder_down() {
  echo ""
  echo "===== 1. rbuilder-down ====="
  echo "  预期：bundle-proxy 触发熔断 → fallback 到 op-geth → 客户端仍返 tx hash（来自 op-geth）"

  echo ""
  echo "[before] fallback 计数器："
  metric "fallback_total"

  echo ""
  echo "[1.1] 停 op-rbuilder ..."
  docker stop mychain-op-rbuilder >/dev/null

  echo "[1.2] 发 20 笔 eth_sendRawTransaction ..."
  ok=0; err=0; fallback_hit=0
  for i in $(seq 1 20); do
    r=$(rpc_send_raw)
    if echo "$r" | grep -qE '"result":"0x[0-9a-f]{64}"'; then
      ok=$((ok+1))
      # 不能从单个响应看出来是 main vs fallback，靠后面 metrics 看
    elif echo "$r" | grep -q '"code":-32002'; then
      err=$((err+1))     # UPSTREAM_FAILED（fallback 也挂）
    else
      err=$((err+1))
    fi
  done
  echo "  20 笔结果：ok=$ok err=$err"

  echo ""
  echo "[after] fallback / outcome 计数器（应见 fallback_total 涨 + rbuilder_fail_fallback_ok / fallback_ok 计数）："
  metric "fallback_total"
  metric "rpc_total" | grep -E "(fallback_ok|rbuilder_fail_fallback_ok|both_failed)" || echo "  (无 fallback 相关 outcome；检查 ENABLE_FALLBACK=true)"

  echo ""
  echo "[1.3] 看熔断器状态（应 = 2 即 OPEN）"
  curl -s "$PROXY/status" | python3 -c "import sys,json;d=json.load(sys.stdin);print(' ',d['circuit'])" 2>/dev/null || true

  echo ""
  echo "[1.4] 恢复 op-rbuilder ..."
  docker start mychain-op-rbuilder >/dev/null
  echo "  等 op-rbuilder healthy（10s）..."
  sleep 10

  echo ""
  echo "[1.5] 等熔断器 HALF_OPEN（5s）后再发 5 笔，看是否切回 CLOSED ..."
  sleep 6
  for i in $(seq 1 5); do rpc_send_raw >/dev/null; done
  sleep 1
  echo "  熔断器现状（应回到 closed）："
  curl -s "$PROXY/status" | python3 -c "import sys,json;d=json.load(sys.stdin);print(' ',d['circuit'])" 2>/dev/null || true

  if [[ $ok -gt 0 ]]; then
    echo ""
    echo "  ✅ rbuilder-down：fallback 路径工作（$ok / 20 笔成功）"
  else
    echo ""
    echo "  ❌ rbuilder-down：所有请求失败。可能：ENABLE_FALLBACK=false / op-geth 也挂了 / fallback 实现 bug"
  fi
}

# =============================================================================
# 场景 2: proxy-overload — 并发超 IN_FLIGHT_LIMIT × 1.5
# =============================================================================
chaos_proxy_overload() {
  echo ""
  echo "===== 2. proxy-overload ====="
  N=$((BUNDLE_PROXY_IN_FLIGHT_LIMIT * 3 / 2))
  echo "  预期：在 IN_FLIGHT_LIMIT=$BUNDLE_PROXY_IN_FLIGHT_LIMIT 下并发 $N 笔，其中 ≥ $((N - BUNDLE_PROXY_IN_FLIGHT_LIMIT)) 笔返 -32000 fail-fast"
  echo "  ⚠️  这个场景需要 op-rbuilder 处理够慢才能堆出 in-flight；若链很闲（200 TPS 以下），可能 in-flight 永远 < limit"

  echo ""
  echo "[before] rejected 计数器："
  metric "rpc_total" | grep "rejected" || echo "  (尚未有 rejected)"

  echo ""
  echo "[2.1] 并发发 $N 笔（异步，不等响应）..."
  # 用 background curl，1 秒内压完
  for i in $(seq 1 $N); do
    rpc_send_raw >/dev/null &
    # 不限速，让 in-flight 飙起来
  done
  wait
  echo "  并发完成"

  sleep 1
  echo ""
  echo "[after] rejected 计数器（应见 outcome=rejected 计数）："
  metric "rpc_total" | grep -E "(rejected|ok|rbuilder)" || true
  echo ""
  echo "  in-flight 当前："
  metric "inflight"

  echo ""
  echo "[2.2] proxy /status saturation："
  curl -s "$PROXY/status" | python3 -c "import sys,json;d=json.load(sys.stdin);print(' ',d['inflight'])" 2>/dev/null || true

  # 验收：rejected 计数 > 0 即通过（具体数字依赖时序）
  rej=$(curl -s "$METRICS" | grep -E '^bundle_proxy_rpc_total\{.*outcome="rejected"' | awk '{print $2}' | head -1)
  rej=${rej:-0}
  if (( $(echo "$rej > 0" | bc -l) )); then
    echo ""
    echo "  ✅ proxy-overload：fail-fast 触发 ${rej%.*} 次"
  else
    echo ""
    echo "  ⚠️  proxy-overload：rejected=0。可能 op-rbuilder 处理太快没堆 in-flight。"
    echo "      尝试加大并发：N_CONCURRENT=3000 bash $0 proxy-overload"
    echo "      或者降低 BUNDLE_PROXY_IN_FLIGHT_LIMIT 重启再试"
  fi
}

# =============================================================================
# 场景 3: flashblocks-rpc-down — 读路径降级
# =============================================================================
chaos_flashblocks_rpc_down() {
  echo ""
  echo "===== 3. flashblocks-rpc-down ====="
  if ! docker inspect mychain-flashblocks-rpc >/dev/null 2>&1; then
    echo "  ℹ️  flashblocks-rpc 未启用（v7.0 默认 optional profile 不起），跳过此场景"
    echo "      启用方式：docker compose --profile flashblocks-rpc up -d flashblocks-rpc"
    return
  fi
  echo "  预期：bundle-proxy 读路径 5xx，依赖业务方 SDK 自行 retry/fallback 到 op-geth；"
  echo "        bundle-proxy 本身不自动重试读（M1 设计，详见 src/rpcRouter.js）"

  echo ""
  echo "[3.1] 停 flashblocks-rpc ..."
  docker stop mychain-flashblocks-rpc >/dev/null

  echo "[3.2] eth_call（预期返 -32002 UPSTREAM_FAILED）"
  r=$(curl -s --max-time 5 "$PROXY" -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x0000000000000000000000000000000000000000"},"latest"],"id":1}')
  echo "  $r"
  if echo "$r" | grep -q '"code":-32002'; then
    echo "  ✅ 读路径 fail-fast 正确返 -32002"
  elif echo "$r" | grep -q '"result"'; then
    echo "  ⚠️  读路径没有报错（可能 BUNDLE_PROXY_READ_TARGET=opgeth 模式，flashblocks-rpc 不在读路径上）"
  fi

  echo "[3.3] 恢复 flashblocks-rpc ..."
  docker start mychain-flashblocks-rpc >/dev/null
  sleep 5
  r=$(curl -s --max-time 5 "$PROXY" -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}')
  echo "  恢复后 eth_chainId: $r"
}

# =============================================================================
# 场景 4: rollup-boost-down — 严重故障（链停摆）
# =============================================================================
chaos_rollup_boost_down() {
  echo ""
  echo "===== 4. rollup-boost-down ====="
  echo "  ⚠️  这是严重故障：rollup-boost 是 op-node 的 engine API 唯一入口，停了链就不出块"
  echo "  预期：op-node 卡住，bundle-proxy 写路径还能收（但 tx 不上链）"

  echo ""
  echo "[4.1] 看当前 head ..."
  bn1=$(curl -s "$PROXY" -H 'content-type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        | grep -oE '"result":"0x[0-9a-f]+"' | grep -oE '0x[0-9a-f]+')
  echo "  head = $bn1 ($((bn1)))"

  echo "[4.2] 停 rollup-boost 10s ..."
  docker stop mychain-rollup-boost >/dev/null
  sleep 10

  echo "[4.3] 再看 head（应等于 4.1 或仅+1，因为出块停了）..."
  bn2=$(curl -s "$PROXY" -H 'content-type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        | grep -oE '"result":"0x[0-9a-f]+"' | grep -oE '0x[0-9a-f]+')
  diff=$((bn2 - bn1))
  echo "  head = $bn2 ($((bn2)))，10s 内涨了 $diff 块"
  if (( diff <= 2 )); then
    echo "  ✅ 出块停摆符合预期（rollup-boost 是单点）"
  else
    echo "  ⚠️  10s 涨了 $diff 块，意味着 boost 不是出块单点？(检查 op-node 是否被 fallback 到直连 op-geth)"
  fi

  echo "[4.4] 恢复 rollup-boost ..."
  docker start mychain-rollup-boost >/dev/null
  sleep 8

  bn3=$(curl -s "$PROXY" -H 'content-type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        | grep -oE '"result":"0x[0-9a-f]+"' | grep -oE '0x[0-9a-f]+')
  echo "  恢复后 head = $bn3 ($((bn3)))"
  if (( bn3 > bn2 )); then
    echo "  ✅ rollup-boost 恢复后链继续出块"
  else
    echo "  ❌ rollup-boost 恢复但 head 不动，需手动看 logs：make flashblocks-logs-rollup-boost"
  fi
}

# =============================================================================
# 主入口
# =============================================================================
case "$SCENARIO" in
  rbuilder-down)         chaos_rbuilder_down ;;
  proxy-overload)        chaos_proxy_overload ;;
  flashblocks-rpc-down)  chaos_flashblocks_rpc_down ;;
  rollup-boost-down)     chaos_rollup_boost_down ;;
  all)
    chaos_rbuilder_down
    sleep 5
    chaos_proxy_overload
    sleep 5
    chaos_flashblocks_rpc_down
    sleep 5
    chaos_rollup_boost_down
    ;;
  *)
    echo "未知 scenario: $SCENARIO"
    echo "可用：rbuilder-down | proxy-overload | flashblocks-rpc-down | rollup-boost-down | all"
    exit 2
    ;;
esac

echo ""
echo "============================================"
echo "✅ chaos 跑完，结果填进 docs/STRESS_TEST_REPORT_V7.md §6 故障注入"
echo "============================================"
