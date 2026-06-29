#!/usr/bin/env bash
# =============================================================================
# stress-soak.sh — 单档 TPS 长跑测试，给最终决定性数字
#
# 跟 stress-stairs.sh 的差异：
#   - stairs：8 档阶梯找拐点，但 mempool 残留 + 短窗口噪声大
#   - soak：单档 5-10 分钟，mempool 充分稳态、最后 2 分钟做严格采样，可信度高
#
# 用法（dev/ 目录下）：
#   bash scripts/stress-soak.sh                           # 默认 TARGET_TPS=200, 600s
#   TARGET_TPS=150 DURATION=300 bash scripts/stress-soak.sh
#   make bot-token-soak                                   # Makefile 入口
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

# === 参数 ===
TARGET_TPS=${TARGET_TPS:-200}
DURATION=${DURATION:-600}              # 总跑时长（秒）
WARMUP=${WARMUP:-60}                   # warmup 不计入采样
SAMPLE_WINDOW=${SAMPLE_WINDOW:-120}    # 末尾 N 秒做最终采样
DRAIN_TIMEOUT=${DRAIN_TIMEOUT:-120}    # 等 mempool 排空最长时间
DRAIN_THRESHOLD=${DRAIN_THRESHOLD:-50}
# fail-fast 测试时设 0：spammer 不做软背压，让链层 fail-fast 暴露给 client
MEMPOOL_BACKPRESSURE=${MEMPOOL_BACKPRESSURE:-1}

ANVIL_IMAGE=${ANVIL_IMAGE:-ghcr.io/foundry-rs/foundry:stable}
DIAG_RPC=${DIAG_RPC_URL_INTERNAL:-http://op-geth:8545}

OUT_DIR=${OUT_DIR:-stress-soak-${TARGET_TPS}tps-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/run.log"
SAMPLES="$OUT_DIR/samples.csv"

exec > >(tee -a "$LOG") 2>&1

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
blue()  { printf "\033[36m%s\033[0m\n" "$*"; }

# === 工具 ===
head_block() {
  local v
  v=$(docker run --rm --network mychain-dev --entrypoint sh \
    -e RPC="$DIAG_RPC" "$ANVIL_IMAGE" -c 'cast block-number --rpc-url $RPC 2>/dev/null' \
    | tr -d '[:space:]')
  case "$v" in (""|*[!0-9]*) v=0;; esac
  echo "$v"
}

mempool_status() {
  local v
  v=$(docker run --rm --network mychain-dev --entrypoint sh \
    -e RPC="$DIAG_RPC" "$ANVIL_IMAGE" -c '
      RES=$(cast rpc txpool_status --rpc-url $RPC 2>/dev/null || echo "{}")
      PENDING=$(echo "$RES" | grep -oE "\"pending\":\"0x[0-9a-f]*\"" | grep -oE "0x[0-9a-f]*" || true)
      QUEUED=$(echo "$RES"  | grep -oE "\"queued\":\"0x[0-9a-f]*\""  | grep -oE "0x[0-9a-f]*" || true)
      P=$(printf "%d" ${PENDING:-0x0} 2>/dev/null || echo 0)
      Q=$(printf "%d" ${QUEUED:-0x0}  2>/dev/null || echo 0)
      echo "$P,$Q"
    ' 2>/dev/null | tr -d '[:space:]' || echo "0,0")
  case "$v" in
    *","*) echo "$v" ;;
    *) echo "0,0" ;;
  esac
}

sum_block_txs() {
  local start=$1 end=$2
  docker run --rm --network mychain-dev --entrypoint sh \
    -e RPC="$DIAG_RPC" -e START="$start" -e END="$end" "$ANVIL_IMAGE" -c '
      total=0
      i=$START
      while [ $i -le $END ]; do
        HEX=$(printf "0x%x" $i)
        BLK=$(cast rpc eth_getBlockByNumber "$HEX" false --rpc-url $RPC 2>/dev/null || echo "")
        N=$(echo "$BLK" | grep -oE "\"transactions\":\[[^]]*\]" | tr -d "\"[]" | tr "," "\n" | grep -c "^0x" 2>/dev/null) || N=0
        case "$N" in (""|*[!0-9]*) N=0;; esac
        total=$((total + N))
        i=$((i + 1))
      done
      echo $total
    ' | tr -d '[:space:]'
}

spammer_stats() {
  local logs last
  logs=$(docker logs --tail 50 mychain-tokenspammer 2>&1 || echo "")
  last=$( { echo "$logs" | grep -E '^\[ *[0-9]+s\] *ok=' | tail -1; } || true )
  if [ -z "$last" ]; then
    echo "0,0,0,0,0"
    return
  fi
  parse_num() {
    local s="${1:-0}"
    s=$(echo "$s" | tr -d ' ,')
    if [[ "$s" =~ ^([0-9.]+)[kK]$ ]]; then awk -v x="${BASH_REMATCH[1]}" 'BEGIN{printf "%d", x*1000}'
    elif [[ "$s" =~ ^([0-9.]+)[mM]$ ]]; then awk -v x="${BASH_REMATCH[1]}" 'BEGIN{printf "%d", x*1000000}'
    elif [[ "$s" =~ ^[0-9]+$ ]]; then echo "$s"
    elif [[ "$s" =~ ^([0-9.]+)$ ]]; then awk -v x="$s" 'BEGIN{printf "%d", x}'
    else echo 0
    fi
  }
  extract() {
    echo "$last" | sed -nE "s/.*${1}=[[:space:]]*([0-9][0-9.,kKmM]*).*/\1/p" | head -1
  }
  echo "$(parse_num "$(extract ok)"),$(parse_num "$(extract fail)"),$(parse_num "$(extract full)"),$(parse_num "$(extract nonce)"),$(parse_num "$(extract other)")"
}

# === Pre-check ===
[ -f .env ] || { red "❌ .env 不存在"; exit 1; }
docker network inspect mychain-dev >/dev/null 2>&1 || { red "❌ mychain-dev 网络不存在"; exit 1; }
docker ps --format '{{.Names}}' | grep -q '^mychain-op-geth$' || { red "❌ op-geth 没运行"; exit 1; }

# === Banner ===
echo "============================================"
blue "🎯 单档长跑测试"
echo "  TARGET_TPS:    $TARGET_TPS"
echo "  DURATION:      ${DURATION}s ($(awk "BEGIN{printf \"%.1f\", $DURATION/60}") 分钟)"
echo "  WARMUP:        ${WARMUP}s（不计入采样）"
echo "  SAMPLE_WINDOW: 末尾 ${SAMPLE_WINDOW}s 做最终采样"
echo "  BACKPRESSURE:  $MEMPOOL_BACKPRESSURE（0=fail-fast 验证模式，1=正常软背压）"
echo "  RPC:           $DIAG_RPC"
echo "  输出目录:      $OUT_DIR"
echo "============================================"
echo ""

# === Step 1: 停旧 spammer + 等 mempool 排空 ===
echo "[1/5] 准备阶段"
make bot-token-spam-down >/dev/null 2>&1 || true

echo "等 mempool 排空（< $DRAIN_THRESHOLD）..."
drained=0
for i in $(seq 1 $((DRAIN_TIMEOUT / 2))); do
  mp=$(mempool_status)
  p=${mp%,*}
  if [ "$p" -lt "$DRAIN_THRESHOLD" ]; then
    green "  ✓ mempool pending=$p（${i}*2s 后）"
    drained=1
    break
  fi
  if [ $((i % 10)) -eq 0 ]; then
    echo "  ⏳ mempool=$mp（已等 $((i*2))s）"
  fi
  sleep 2
done
if [ "$drained" -eq 0 ]; then
  yellow "  ⚠️  ${DRAIN_TIMEOUT}s 后 mempool 仍 ≥ $DRAIN_THRESHOLD，继续（数据可能受残留影响）"
fi

# === Step 2: 启动 spammer ===
echo ""
echo "[2/5] 启动 spammer TARGET_TPS=$TARGET_TPS BACKPRESSURE=$MEMPOOL_BACKPRESSURE"
# 显式 pass 两个 env，防 .env 覆盖 / shell 透传链断
TARGET_TPS=$TARGET_TPS MEMPOOL_BACKPRESSURE=$MEMPOOL_BACKPRESSURE \
  make bot-token-spam-up >/dev/null
sleep 3
docker ps --format '{{.Names}}' | grep -q '^mychain-tokenspammer$' \
  || { red "❌ spammer 没起来"; exit 1; }

# 验证 spammer 容器实际拿到的 env（防被 .env 覆盖）
actual_target=$(docker inspect mychain-tokenspammer \
  --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | grep -E '^TARGET_TPS=' | tail -1 | cut -d= -f2 || echo "")
actual_bp=$(docker inspect mychain-tokenspammer \
  --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | grep -E '^MEMPOOL_BACKPRESSURE=' | tail -1 | cut -d= -f2 || echo "")
if [ -n "$actual_target" ] && [ "$actual_target" != "$TARGET_TPS" ]; then
  yellow "  ⚠️  spammer 容器内 TARGET_TPS=$actual_target（不是 $TARGET_TPS！）"
  yellow "      .env 里可能有 TARGET_TPS 覆盖。请检查并删除"
fi
if [ -n "$actual_bp" ] && [ "$actual_bp" != "$MEMPOOL_BACKPRESSURE" ]; then
  yellow "  ⚠️  spammer 容器内 BACKPRESSURE=$actual_bp（不是 $MEMPOOL_BACKPRESSURE！）"
fi
echo "  spammer 容器实际 TARGET_TPS=${actual_target:-?} BACKPRESSURE=${actual_bp:-?}"

# === Step 3: warmup ===
echo ""
echo "[3/5] warmup ${WARMUP}s..."
sleep "$WARMUP"

# === Step 4: 主测试期 ===
echo ""
echo "[4/5] 主测试期：${DURATION}s 持续观察"
echo "tick_t,wall_clock,head_block,mp_pending,mp_queued,spammer_ok,spammer_fail,fail_full" > "$SAMPLES"

start_t=$(date +%s)
test_start_block=$(head_block)

# 用 wall_clock 控制循环（不是固定循环次数），避免 docker run 慢导致总时长漂移
# 关键：sleep 30 后取 head_block / mempool / spammer_stats 每次 docker run 启动 5-30s
# 所以循环实际间隔可能是 30-100s，total wall_clock 远超 DURATION
tick=0
while true; do
  now_t=$(date +%s)
  wall=$((now_t - start_t))
  if [ $wall -ge $DURATION ]; then
    break
  fi
  # 下一个采样点在 wall_clock = (tick+1)*30，但如果当前已经超过，立即采样
  next_target=$(( (tick + 1) * 30 ))
  if [ $wall -lt $next_target ]; then
    sleep_t=$((next_target - wall))
    [ $sleep_t -gt 0 ] && sleep $sleep_t
  fi
  tick=$((tick + 1))
  now_t=$(date +%s)
  wall=$((now_t - start_t))
  hb=$(head_block)
  mp=$(mempool_status)
  spam=$(spammer_stats)
  IFS=',' read -r s_ok s_fail s_full _ _ <<< "$spam"
  echo "  t=+${wall}s head=$hb mempool=${mp/,/+} spammer(ok=$s_ok fail=$s_fail full=$s_full)"
  echo "$tick,$wall,$hb,${mp%,*},${mp#*,},$s_ok,$s_fail,$s_full" >> "$SAMPLES"
done

# 记录真实结束时间
test_end_t=$(date +%s)
actual_duration=$((test_end_t - start_t))
test_end_block=$(head_block)
mp_final=$(mempool_status)

# === Step 5: 严格采样 = 最后 SAMPLE_WINDOW 秒 ===
# 关键修复：用真实 wall_clock 而不是名义 SAMPLE_WINDOW 算 chain_tps
# 否则当 docker run 启动慢导致循环间隔 > 30s 时，"末尾 SAMPLE_WINDOW 秒"
# 实际包含的 wall_clock 远超 SAMPLE_WINDOW，但 chain_tps = total / SAMPLE_WINDOW
# 会严重偏高（v1 实测一次显示 chain_tps=476 但实际 ~164）
echo ""
echo "[5/5] 计算最终结果"

# 找采样窗口起始：从 samples.csv 找 wall_clock = (actual_duration - SAMPLE_WINDOW) 时的第一条采样
sample_start_t=$((actual_duration - SAMPLE_WINDOW))
[ "$sample_start_t" -lt 0 ] && sample_start_t=0
window_start_line=$(awk -F, -v target="$sample_start_t" 'NR>1 && $2>=target {print $0; exit}' "$SAMPLES")

if [ -z "$window_start_line" ] || [ "$(echo "$window_start_line" | cut -d, -f3)" -ge "$test_end_block" ]; then
  yellow "  ⚠️  采样窗口数据不足，用全程作为最终结果"
  window_start_block=$test_start_block
  window_start_wall=0
  effective_window=$actual_duration
else
  window_start_block=$(echo "$window_start_line" | cut -d, -f3)
  window_start_wall=$(echo "$window_start_line" | cut -d, -f2)
  # 真实窗口 = end_wall_clock - 起始采样的 wall_clock
  effective_window=$((actual_duration - window_start_wall))
fi

window_blocks=$((test_end_block - window_start_block))
echo ""
echo "🔍 严格采样（末尾真实 ${effective_window}s 稳态）..."
echo "  范围：($window_start_block, $test_end_block] = $window_blocks 块"
echo "  时间：wall_clock [$window_start_wall, $actual_duration] = $effective_window 秒（真实）"
window_total=$(sum_block_txs "$((window_start_block + 1))" "$test_end_block")
final_chain_tps=0
[ "$effective_window" -gt 0 ] && final_chain_tps=$((window_total / effective_window))
final_tx_per_block=0
[ "$window_blocks" -gt 0 ] && final_tx_per_block=$((window_total / window_blocks))

# 全程 TPS：用真实 wall_clock
total_blocks=$((test_end_block - test_start_block))
total_txs=$(sum_block_txs "$((test_start_block + 1))" "$test_end_block")
overall_tps=0
[ "$actual_duration" -gt 0 ] && overall_tps=$((total_txs / actual_duration))

# === 输出最终结论 ===
echo ""
echo "============================================"
green "🎯 长跑结果"
echo "============================================"
echo ""
echo "📊 总体（设定 ${DURATION}s / 真实 ${actual_duration}s 全程）："
echo "    blocks            ${total_blocks}"
echo "    total tx          ${total_txs}"
echo "    overall chain_tps ${overall_tps}  (= total_tx / 真实秒数)"
echo ""
echo "🔬 严格采样（末尾 ${effective_window}s 稳态）："
echo "    blocks            ${window_blocks}"
echo "    total tx          ${window_total}"
echo "    avg tx/block      ${final_tx_per_block}"
echo "    chain_tps         ${final_chain_tps}"
echo ""
mp_p=${mp_final%,*}
mp_q=${mp_final#*,}
echo "📦 末尾 mempool：    pending=$mp_p queued=$mp_q"
echo ""

# 评判
ratio=$(awk "BEGIN{if($TARGET_TPS==0)print 0; else printf \"%.2f\", $final_chain_tps / $TARGET_TPS}")
echo "🎯 评判（target=$TARGET_TPS, 稳态 chain_tps=$final_chain_tps, ratio=$ratio）："
if awk "BEGIN{exit !($ratio >= 0.95)}"; then
  green "    ✅ TARGET 达成 — 链能完全消化 $TARGET_TPS TPS"
elif [ "$mp_p" -gt 5000 ]; then
  red "    ❌ OVERLOAD — mempool 雪崩，链已不健康"
  echo "       链稳态消化能力：~$final_chain_tps TPS（< target $TARGET_TPS）"
else
  yellow "    ⚠️  DEGRADED — 链消化能力 < target，mempool 在累积"
  echo "       链稳态消化能力：~$final_chain_tps TPS"
fi
echo ""

# 保存 spammer log
docker logs --tail 200 mychain-tokenspammer > "$OUT_DIR/spammer.log" 2>&1 || true

# === 收尾 ===
make bot-token-spam-down >/dev/null 2>&1 || true
echo "📁 详细数据：$OUT_DIR/"
echo "    - samples.csv     30s 间隔的采样点"
echo "    - run.log         全运行日志"
echo "    - spammer.log     spammer 最后 200 行"
