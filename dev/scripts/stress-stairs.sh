#!/usr/bin/env bash
# =============================================================================
# stress-stairs.sh — 阶梯式 TPS 压测，找出链真实承载上限
#
# 用法（dev/ 目录下）：
#   bash scripts/stress-stairs.sh
#   TPS_LIST="100 200 300 500" DURATION=120 bash scripts/stress-stairs.sh
#   make bot-token-stairs                         # 推荐
#
# 流程（每档）：
#   1. 停旧 spammer
#   2. 等 mempool < 100（最多 60s）
#   3. TARGET_TPS=N make bot-token-spam-up
#   4. warmup 30s（不计入采样）
#   5. 记录起始 block
#   6. 等剩余时间
#   7. 记录结束 block
#   8. 累加范围内每块 tx 数 → chain_tps = total / duration
#   9. 记录末尾 mempool / spammer 累计 ok+fail
#  10. 写 CSV 一行
#
# 输出：
#   stress-stairs-YYYYMMDD-HHMMSS/
#     ├── results.csv       主表
#     ├── run.log           全运行日志
#     └── spammer-N.log     每档 spammer 最后 100 行
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."  # 进 dev/

# === 参数（环境变量覆盖）===
# 默认 TPS_LIST 100-350：实测 v1 显示链消化 100-150 TPS，> 350 退化到 ~100，无信息量
TPS_LIST=${TPS_LIST:-"100 150 200 250 300 350"}
DURATION=${DURATION:-180}              # 每档总持续秒数
WARMUP=${WARMUP:-45}                   # 启动后预热（不计入采样）
DRAIN_TIMEOUT=${DRAIN_TIMEOUT:-120}    # 等 mempool 排空最长时间
DRAIN_THRESHOLD=${DRAIN_THRESHOLD:-30}  # mempool pending < 此值视为已排空（v1=100 太松）
COOL_DOWN=${COOL_DOWN:-30}             # 排空后额外冷却秒数，让链彻底稳态

ANVIL_IMAGE=${ANVIL_IMAGE:-ghcr.io/foundry-rs/foundry:stable}
DIAG_RPC=${DIAG_RPC_URL_INTERNAL:-http://op-geth:8545}

OUT_DIR=${OUT_DIR:-stress-stairs-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/run.log"
CSV="$OUT_DIR/results.csv"

# 全部输出同时打到 log
exec > >(tee -a "$LOG") 2>&1

# === 颜色 ===
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
blue()  { printf "\033[36m%s\033[0m\n" "$*"; }

# === 工具：通过 cast 读链状态 ===
# 用一个常驻容器 + docker exec 太复杂，每次 docker run 启动一个 cast 容器更简单（~1s overhead 可接受）
cast_rpc() {
  docker run --rm --network mychain-dev --entrypoint sh \
    -e RPC="$DIAG_RPC" "$ANVIL_IMAGE" -c "cast rpc $* --rpc-url \$RPC"
}

# 取最新 block number（decimal）
head_block() {
  local v
  v=$(docker run --rm --network mychain-dev --entrypoint sh \
    -e RPC="$DIAG_RPC" "$ANVIL_IMAGE" -c 'cast block-number --rpc-url $RPC 2>/dev/null' \
    | tr -d '[:space:]')
  case "$v" in (""|*[!0-9]*) v=0;; esac
  echo "$v"
}

# 等链稳定出块（连续 5s 内增长 ≤ 3 块），避免 op-geth 重启后 catch-up 期取样
# 重启后 op-geth 会从 safe head 重放 unsafe blocks，期间出块速率比正常快 5-10x，
# 此时取 block_diff 算 TPS 严重失真（1026 块/150s 这种）
wait_for_steady_block() {
  local max_wait=${1:-60}
  local elapsed=0
  echo "等链出块速率稳定到 ~1 块/秒..."
  while [ $elapsed -lt $max_wait ]; do
    local b1 b2
    b1=$(head_block)
    sleep 5
    b2=$(head_block)
    local diff=$((b2 - b1))
    if [ $diff -ge 0 ] && [ $diff -le 8 ]; then
      green "  ✓ 5s 出 $diff 块（正常 ~5），稳定"
      return 0
    fi
    yellow "  ⏳ 5s 出 $diff 块，仍在追赶..."
    elapsed=$((elapsed + 5))
  done
  yellow "  ⚠️  ${max_wait}s 后仍未稳定，继续测试（数据可能不准）"
  return 1
}

# 取 [start, end] 范围内累计 tx 数（包含两端）
# 用 cast 一次性取一个块，自己数 tx hash —— 比 eth_getBlockTransactionCountByNumber 多一次 RPC
# 但稳定（不受不同节点 RPC 实现差异影响）
sum_block_txs() {
  local start=$1 end=$2
  docker run --rm --network mychain-dev --entrypoint sh \
    -e RPC="$DIAG_RPC" -e START="$start" -e END="$end" "$ANVIL_IMAGE" -c '
      total=0
      i=$START
      while [ $i -le $END ]; do
        HEX=$(printf "0x%x" $i)
        BLK=$(cast rpc eth_getBlockByNumber "$HEX" false --rpc-url $RPC 2>/dev/null || echo "")
        # 数 transactions 数组里有几个 0x。grep -c 总是输出一个数字（即使为 0），
        # 但 exit code 在 0 个匹配时是 1，必须用 true 兜底防止 set -e 跳出
        N=$(echo "$BLK" | grep -oE "\"transactions\":\[[^]]*\]" | tr -d "\"[]" | tr "," "\n" | grep -c "^0x" 2>/dev/null) || N=0
        # 严格数字化（防 N 为空或非数字）
        case "$N" in (""|*[!0-9]*) N=0;; esac
        total=$((total + N))
        i=$((i + 1))
      done
      echo $total
    ' | tr -d '[:space:]'
}

# 取 mempool {pending, queued} 用 "pending,queued" 格式
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
  # sanity check
  case "$v" in
    *","*) echo "$v" ;;
    *) echo "0,0" ;;
  esac
}

# 取 spammer 累计 ok/fail（从 docker logs 倒数最后一行 report）
# 输出 "ok,fail,full,nonce,other"，找不到时全 0
# k/M 后缀：spammer js 里 fmtNum() 用 .padStart(...) 对齐数字，并不会自动加 k/M。
# 但是当数字极大时（百万级）会用科学计数法。这里用宽松解析覆盖几种格式。
spammer_stats() {
  # spammer 输出（v5 格式）：
  #   [   30s] ok=    7,410 fail=      0 tps(rec)=  50 ftps(rec)=   0 ...
  # 注意：fmtNum 用 toLocaleString → 数字带逗号；padStart 让 = 后有空格
  # grep 必须接受空格 + 逗号
  local logs last
  logs=$(docker logs --tail 50 mychain-tokenspammer 2>&1 || echo "")
  last=$( { echo "$logs" | grep -E '^\[ *[0-9]+s\] *ok=' | tail -1; } || true )

  if [ -z "$last" ]; then
    echo "0,0,0,0,0"
    return
  fi

  # parse_num: 接受 "1,234" / "12.5k" / "3.4M" / 纯整数
  parse_num() {
    local s="${1:-0}"
    s=$(echo "$s" | tr -d ' ,')
    if [[ "$s" =~ ^([0-9.]+)[kK]$ ]]; then
      awk -v x="${BASH_REMATCH[1]}" 'BEGIN{printf "%d", x*1000}'
    elif [[ "$s" =~ ^([0-9.]+)[mM]$ ]]; then
      awk -v x="${BASH_REMATCH[1]}" 'BEGIN{printf "%d", x*1000000}'
    elif [[ "$s" =~ ^[0-9]+$ ]]; then
      echo "$s"
    elif [[ "$s" =~ ^([0-9.]+)$ ]]; then
      awk -v x="$s" 'BEGIN{printf "%d", x}'
    else
      echo 0
    fi
  }

  # 用 sed/awk 提取（grep -oE 不支持非贪婪），格式：keyword= 后接空格 + 数字（可能带逗号/k/M）
  extract() {
    local key="$1"
    # 匹配 "key=    7,410" → 输出 "7,410"
    echo "$last" | sed -nE "s/.*${key}=[[:space:]]*([0-9][0-9.,kKmM]*).*/\1/p" | head -1
  }

  local ok_str fail_str full_str nonce_str other_str
  ok_str=$(extract 'ok')
  fail_str=$(extract 'fail')
  full_str=$(extract 'full')
  nonce_str=$(extract 'nonce')
  other_str=$(extract 'other')

  echo "$(parse_num "$ok_str"),$(parse_num "$fail_str"),$(parse_num "$full_str"),$(parse_num "$nonce_str"),$(parse_num "$other_str")"
}

# === Pre-check ===
if [ ! -f .env ]; then
  red "❌ .env 不存在，先复制：cp .env.example .env"
  exit 1
fi

if ! docker network inspect mychain-dev >/dev/null 2>&1; then
  red "❌ mychain-dev 网络不存在，链没起？先 make dev-up"
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q '^mychain-op-geth$'; then
  red "❌ mychain-op-geth 没运行，先 make dev-up"
  exit 1
fi

# 启动前等链稳定（如果刚 clear-mempool 过，op-geth 可能还在 catch-up）
echo ""
yellow "🔍 起跑前先确认链出块速率稳定..."
wait_for_steady_block 90 || true

# === Banner ===
echo "============================================"
blue "📊 阶梯压测开始"
echo "  TPS_LIST:    $TPS_LIST"
echo "  DURATION:    ${DURATION}s / 档（含 ${WARMUP}s warmup）"
echo "  采样窗口:    $((DURATION - WARMUP))s"
echo "  RPC:         $DIAG_RPC"
echo "  输出目录:    $OUT_DIR"
echo "  开始时间:    $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

# 估算总耗时
n_steps=$(echo "$TPS_LIST" | wc -w)
total_min=$(awk "BEGIN{printf \"%.1f\", $n_steps * ($DURATION + 30) / 60}")
echo "  预计耗时:    约 ${total_min} 分钟"
echo ""

# === CSV header ===
echo "tps_target,duration_s,start_block,end_block,blocks,total_txs,chain_tps,chain_tps_ratio,mp_pending_end,mp_queued_end,spammer_ok,spammer_fail,fail_full,fail_nonce,fail_other,verdict" > "$CSV"

# === 主循环 ===
for tps in $TPS_LIST; do
  echo ""
  echo "============================================"
  blue "🎯 TARGET_TPS=$tps  ($(date '+%H:%M:%S'))"
  echo "============================================"

  # 1. 停旧 spammer
  make bot-token-spam-down >/dev/null 2>&1 || true

  # 2. 等 mempool 严格排空到 < DRAIN_THRESHOLD（默认 30）
  echo "等 mempool 严格排空（< $DRAIN_THRESHOLD）..."
  drained=0
  for i in $(seq 1 $((DRAIN_TIMEOUT / 2))); do
    mp=$(mempool_status 2>/dev/null || echo "0,0")
    p=${mp%,*}
    if [ "$p" -lt "$DRAIN_THRESHOLD" ]; then
      green "  ✓ mempool pending=$p（${i}*2s 后）"
      drained=1
      break
    fi
    if [ $((i % 5)) -eq 0 ]; then
      echo "  ⏳ mempool=$mp（已等 $((i*2))s）"
    fi
    sleep 2
  done
  if [ "$drained" -eq 0 ]; then
    yellow "  ⚠️  mempool 未排空（${DRAIN_TIMEOUT}s timeout），数据可能偏高（残留消化）"
  fi

  # 2.5. 额外冷却：让链彻底进入 idle 稳态，避免出块速率异常 ramp
  if [ "$COOL_DOWN" -gt 0 ]; then
    echo "冷却 ${COOL_DOWN}s（让链彻底稳态）..."
    sleep "$COOL_DOWN"
  fi

  # 3. 启动 spammer
  echo "启动 spammer TARGET_TPS=$tps..."
  TARGET_TPS=$tps make bot-token-spam-up >/dev/null

  # 4. warmup
  echo "warmup ${WARMUP}s..."
  sleep "$WARMUP"

  # 5. 记录起始 block
  start_block=$(head_block)
  echo "📍 采样窗口起始 block=$start_block"

  # 6. 跑剩余时间，期间每 30s 打印一次 mempool
  remaining=$((DURATION - WARMUP))
  echo "持续 ${remaining}s..."
  intervals=$((remaining / 30))
  last_remain=$((remaining - intervals * 30))
  for i in $(seq 1 $intervals); do
    sleep 30
    mp=$(mempool_status 2>/dev/null || echo "?,?")
    spam=$(spammer_stats 2>/dev/null || echo "?,?,?,?,?")
    echo "  t=+$((WARMUP + i*30))s  mempool=${mp/,/+}  spammer(ok,fail,full,nonce,other)=$spam"
  done
  [ "$last_remain" -gt 0 ] && sleep "$last_remain"

  # 7. 结束块
  end_block=$(head_block)
  blocks=$((end_block - start_block))
  echo "📍 采样窗口结束 block=$end_block （+$blocks 块 / ${remaining}s 期望）"

  # 8. 累加 tx 数：扫 (start, end]
  # chain_tps 基于真实采样秒数（remaining）算 = wall-clock 视角"链每秒处理多少 tx"
  # blocks 数量本身不重要：OP Stack op-node sequencer 在有 batch 处理时一次给 op-geth
  # push 多个 newPayload 是正常行为，可能 wall-clock 1s 出 1-3 个块。chain_tps 公式与
  # blocks 无关，仍然可信。但是如果 blocks 严重低于 remaining（< 50%），说明链 stall 或
  # 网络问题，标记为 STALL
  anomaly=""
  if [ "$blocks" -lt 1 ]; then
    yellow "  ⚠️  没出块？跳过"
    total=0
    chain_tps=0
    anomaly="NO_BLOCKS"
  else
    echo "扫描 ($start_block, $end_block] = $blocks 块累计 tx 数..."
    total=$(sum_block_txs "$((start_block + 1))" "$end_block")
    chain_tps=$((total / remaining))
    # 只标记 stall 情况（blocks < remaining*0.5），不再标 BLOCK_RATE_ABNORMAL
    block_stall_threshold=$((remaining / 2))
    if [ "$blocks" -lt "$block_stall_threshold" ]; then
      anomaly="STALL(${blocks}vs${remaining})"
      yellow "  ⚠️  $blocks 块 / ${remaining}s 预期，出块严重不足（链 stall？）"
    fi
  fi
  echo "📊 ${blocks} 块共 ${total} tx / ${remaining}s → chain_tps ≈ $chain_tps"

  # 9. 末尾 mempool + spammer
  mp_end=$(mempool_status 2>/dev/null || echo "0,0")
  mp_p=${mp_end%,*}
  mp_q=${mp_end#*,}

  spam=$(spammer_stats)
  IFS=',' read -r s_ok s_fail s_full s_nonce s_other <<< "$spam"

  # 10. 评判
  ratio=$(awk "BEGIN{if($tps==0)print 0; else printf \"%.2f\", $chain_tps / $tps}")
  if [ -n "$anomaly" ]; then
    verdict=$(yellow "ANOMALY:$anomaly")
    verdict_raw="ANOMALY:$anomaly"
  elif awk "BEGIN{exit !($ratio >= 0.95)}"; then
    verdict=$(green "OK")
    verdict_raw="OK"
  elif [ "$mp_p" -gt 5000 ]; then
    verdict=$(red "OVERLOAD")
    verdict_raw="OVERLOAD"
  else
    verdict=$(yellow "DEGRADED")
    verdict_raw="DEGRADED"
  fi

  echo "  TARGET=$tps  CHAIN=$chain_tps  ratio=$ratio  mempool=${mp_p}+${mp_q}  $verdict"

  # 11. 写 CSV
  echo "$tps,$remaining,$start_block,$end_block,$blocks,$total,$chain_tps,$ratio,$mp_p,$mp_q,$s_ok,$s_fail,$s_full,$s_nonce,$s_other,$verdict_raw" >> "$CSV"

  # 12. spammer log 备份
  docker logs --tail 100 mychain-tokenspammer > "$OUT_DIR/spammer-$tps.log" 2>&1 || true

  # 早停：连续两档 OVERLOAD 直接停止（已经超过承载上限）
  if [ "$verdict_raw" = "OVERLOAD" ]; then
    last_two=$(awk -F, 'NR>1{print $NF}' "$CSV" | tail -2)
    overload_count=$(echo "$last_two" | grep -c '^OVERLOAD$' || true)
    if [ "${overload_count:-0}" -ge 2 ]; then
      yellow "⚠️  连续 OVERLOAD，提前停止（链已明显超载）"
      break
    fi
  fi
done

# === 收尾 ===
echo ""
echo "============================================"
blue "🎯 测试完成 $(date '+%H:%M:%S')"
echo "============================================"
make bot-token-spam-down >/dev/null 2>&1 || true

# 清掉 mempool（不影响其他测试）
echo "等待 mempool 自然消化..."
sleep 5

# === 汇总输出 ===
echo ""
echo "📊 阶梯压测结果："
echo ""
column -t -s, "$CSV" 2>/dev/null || cat "$CSV"

echo ""
echo "📈 拐点分析（chain_tps / target_tps）："
awk -F, 'NR>1 {
  printf "  TARGET=%4d  CHAIN=%4d  ratio=%5s  mp=%d+%d  %s\n",
    $1, $7, $8, $9, $10, $NF
}' "$CSV"

echo ""
yellow "⚠️  解读建议："
echo "  - ratio ≥ 0.95 = 链能完全消化（OK）"
echo "  - ratio < 0.95 + mempool 稳定 = 链消化能力下限到达，但没雪崩（DEGRADED）"
echo "  - mempool > 5000 = 链已雪崩（OVERLOAD），数据已不可信"
echo ""
echo "  '链承载上限' = 最后一个 OK 档位的 chain_tps"
echo ""
echo "📁 完整数据：$OUT_DIR/"
echo "  - results.csv"
echo "  - run.log"
echo "  - spammer-*.log"
