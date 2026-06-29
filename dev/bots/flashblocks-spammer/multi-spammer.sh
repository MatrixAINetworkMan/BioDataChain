#!/usr/bin/env bash
# =============================================================================
# Phase 1.6 多进程 spammer：找 builder 真极限
#
# 单 Node.js 进程在 800 TPS 时已经撞 ECDSA 签名 + libuv worker 上限（Phase 1.5
# §12.2 实测）。要找 op-rbuilder 真实算力上限，必须真并发——起 N 个独立 spammer
# 容器，每个用不同的 anvil funder（避免 nonce 冲突），打同一个 builder。
#
# funder 账户：从环境变量 / .env 注入（勿入仓真实 key），需各有足够余额。
# 示例：用 anvil 默认 10 个 deterministic 账户时，[0] 被 builder 占用，
# [1]-[9] 可用，所以最多并发 9 个 spammer。
#
# 用法：
#   bash multi-spammer.sh                       # 默认 4 进程 × 800 TPS = 3200 TPS
#   N_PARALLEL=6 TPS_PER=800 bash multi-spammer.sh   # 6 × 800 = 4800 TPS
#   N_PARALLEL=8 TPS_PER=600 bash multi-spammer.sh   # 8 × 600 = 4800 TPS（每进程压低，看是不是 spammer 限速）
#
# 输出：logs/multi-spammer-<时间戳>/
#   ├── 0.log ... N.log    每个 spammer 完整 FINAL REPORT
#   ├── chain-tps.txt      multi 结束后链上 30-block 窗口 chain-wide TPS（去重计数）
#   └── summary.txt        各 spammer 数字 + 关键聚合指标
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"

N_PARALLEL="${N_PARALLEL:-4}"
TPS_PER="${TPS_PER:-800}"
SENDERS_PER="${SENDERS_PER:-200}"
DURATION_S="${DURATION_S:-30}"
DRAIN_S="${DRAIN_S:-20}"
HTTP_POOL_SIZE="${HTTP_POOL_SIZE:-32}"
HTTP_PIPELINE="${HTTP_PIPELINE:-8}"
RPC_URL="${RPC_URL:-http://127.0.0.1:8547}"      # op-rbuilder
READ_RPC_URL="${READ_RPC_URL:-http://127.0.0.1:8548}"  # flashblocks-rpc

# funder keys：从环境变量或 .env 注入，勿入仓真实私钥。
# 每个进程用不同的 funder（避免 nonce 冲突），最多并发 9 个。
# 占位符列表——运行前请导出 FUNDER_KEY_1..9 或在 .env 里填好。
FUNDER_KEYS=(
  "${FUNDER_KEY_1:-0x<FUNDER_PRIVATE_KEY_1>}"
  "${FUNDER_KEY_2:-0x<FUNDER_PRIVATE_KEY_2>}"
  "${FUNDER_KEY_3:-0x<FUNDER_PRIVATE_KEY_3>}"
  "${FUNDER_KEY_4:-0x<FUNDER_PRIVATE_KEY_4>}"
  "${FUNDER_KEY_5:-0x<FUNDER_PRIVATE_KEY_5>}"
  "${FUNDER_KEY_6:-0x<FUNDER_PRIVATE_KEY_6>}"
  "${FUNDER_KEY_7:-0x<FUNDER_PRIVATE_KEY_7>}"
  "${FUNDER_KEY_8:-0x<FUNDER_PRIVATE_KEY_8>}"
  "${FUNDER_KEY_9:-0x<FUNDER_PRIVATE_KEY_9>}"
)

if (( N_PARALLEL > ${#FUNDER_KEYS[@]} )); then
  echo "ERROR: N_PARALLEL=$N_PARALLEL > ${#FUNDER_KEYS[@]}（最多 9 个可用 funder）"
  exit 1
fi

TS=$(date +%Y%m%d-%H%M%S)
DIR="logs/multi-spammer-$TS"
mkdir -p "$DIR"

TARGET_TOTAL=$(( N_PARALLEL * TPS_PER ))

echo "==========================================="
echo "  Phase 1.6 多进程 spammer 极限测试 ($TS)"
echo "  N_PARALLEL=$N_PARALLEL × TPS_PER=$TPS_PER = TARGET TOTAL = $TARGET_TOTAL TPS"
echo "  per spammer: $SENDERS_PER senders, ${DURATION_S}s spam + ${DRAIN_S}s drain"
echo "  pool=$HTTP_POOL_SIZE × pipe=$HTTP_PIPELINE per spammer"
echo "  output: $DIR/"
echo "==========================================="

if [[ ! -d node_modules ]]; then
  echo ""
  echo "=== 装依赖（一次性）==="
  docker run --rm -v "$(pwd)":/app -w /app node:20-alpine npm install
fi

# 记录 spam 起始链头（用于事后算 chain-wide TPS）
HEAD_BEFORE=$(curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  "$READ_RPC_URL" | sed -E 's/.*"result":"0x([^"]+)".*/\1/')
HEAD_BEFORE=$((16#$HEAD_BEFORE))
echo "head before spam = $HEAD_BEFORE"

# ----------------------------------------------------------------------------
# 并发启 N 个 spammer container，错开 200ms 启动避免 funder 注资雪崩
# ----------------------------------------------------------------------------
PIDS=()
for i in $(seq 0 $((N_PARALLEL - 1))); do
  funder_key="${FUNDER_KEYS[$i]}"
  name="fb-spam-multi-$i"
  log="$DIR/$i.log"

  docker rm -f "$name" 2>/dev/null > /dev/null

  echo "[start] spammer $i: funder=Anvil[$((i+1))]  name=$name  -> $log"
  (
    docker run --rm --network host -v "$(pwd)":/app -w /app \
      -e RPC_URL="$RPC_URL" \
      -e READ_RPC_URL="$READ_RPC_URL" \
      -e FUNDER_KEY="$funder_key" \
      -e TARGET_TPS="$TPS_PER" \
      -e N_SENDERS="$SENDERS_PER" \
      -e DURATION_S="$DURATION_S" \
      -e DRAIN_S="$DRAIN_S" \
      -e HTTP_POOL_SIZE="$HTTP_POOL_SIZE" \
      -e HTTP_PIPELINE="$HTTP_PIPELINE" \
      -e ERR_SAMPLES_MAX=20 \
      --name "$name" \
      node:20-alpine \
      node spammer.js > "$log" 2>&1
  ) &
  PIDS+=($!)
  sleep 0.2
done

echo ""
echo "等 ${#PIDS[@]} 个 spammer 完成（duration $DURATION_S + drain $DRAIN_S = ~$((DURATION_S+DRAIN_S))s）..."
for pid in "${PIDS[@]}"; do
  wait "$pid"
done

# ----------------------------------------------------------------------------
# 记录 spam 结束后链头
# ----------------------------------------------------------------------------
HEAD_AFTER=$(curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  "$READ_RPC_URL" | sed -E 's/.*"result":"0x([^"]+)".*/\1/')
HEAD_AFTER=$((16#$HEAD_AFTER))
SPAM_BLOCKS=$(( HEAD_AFTER - HEAD_BEFORE ))
echo ""
echo "head after spam = $HEAD_AFTER  (advanced $SPAM_BLOCKS blocks)"

# ----------------------------------------------------------------------------
# Chain-wide TPS：扫所有 spam 期间的 block，去重计数（替代各 spammer 自测窗口）
# ----------------------------------------------------------------------------
echo ""
echo "=== Chain-wide TPS 计算（block $((HEAD_BEFORE+1)) ~ $HEAD_AFTER）==="
TOTAL_TXS=0
MAX_BLOCK_TXS=0
MAX_BLOCK_NUM=0
for ((b=HEAD_BEFORE+1; b<=HEAD_AFTER; b++)); do
  hex=$(printf '%x' "$b")
  cnt_hex=$(curl -s -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockTransactionCountByNumber\",\"params\":[\"0x$hex\"],\"id\":1}" \
    "$READ_RPC_URL" | sed -E 's/.*"result":"0x([^"]+)".*/\1/')
  cnt=$((16#$cnt_hex))
  TOTAL_TXS=$(( TOTAL_TXS + cnt ))
  if (( cnt > MAX_BLOCK_TXS )); then
    MAX_BLOCK_TXS=$cnt
    MAX_BLOCK_NUM=$b
  fi
done
SYSTEM_TX_PER_BLOCK=2  # builder attestation 等
USER_TXS=$(( TOTAL_TXS - SPAM_BLOCKS * SYSTEM_TX_PER_BLOCK ))
if (( SPAM_BLOCKS > 0 )); then
  CHAIN_TPS=$(awk -v t=$TOTAL_TXS -v b=$SPAM_BLOCKS 'BEGIN{printf "%.1f", t/b}')
  USER_TPS=$(awk -v u=$USER_TXS -v b=$SPAM_BLOCKS 'BEGIN{printf "%.1f", u/b}')
else
  CHAIN_TPS=0
  USER_TPS=0
fi

{
  echo "blocks scanned:       $SPAM_BLOCKS  (block $((HEAD_BEFORE+1)) ~ $HEAD_AFTER)"
  echo "total txs:            $TOTAL_TXS"
  echo "user txs (-${SYSTEM_TX_PER_BLOCK}/blk system):   $USER_TXS"
  echo "chain-wide TPS:       $CHAIN_TPS"
  echo "user TPS:             $USER_TPS"
  echo "max txs single block: $MAX_BLOCK_TXS  (at #$MAX_BLOCK_NUM)"
  echo "block gas limit:      100,000,000 → max possible = $((100000000/21000)) tx/block"
} | tee "$DIR/chain-tps.txt"

# ----------------------------------------------------------------------------
# 各 spammer 的 sent/ok/err 汇总
# ----------------------------------------------------------------------------
echo ""
echo "=== 各 spammer 数字 ==="
SUMMARY="$DIR/summary.txt"
{
  echo "Phase 1.6 multi-spammer summary ($TS)"
  echo ""
  echo "TARGET_TOTAL = $N_PARALLEL × $TPS_PER = $TARGET_TOTAL TPS"
  echo "per spammer: $SENDERS_PER senders, ${DURATION_S}s spam + ${DRAIN_S}s drain, pool=$HTTP_POOL_SIZE pipe=$HTTP_PIPELINE"
  echo ""
  printf "%-4s %-10s %-10s %-8s %-12s %-10s %-10s\n" \
    "ID" "sent" "ok" "err%" "incl%" "p50ms" "selfTPS"
  echo "-----------------------------------------------------------------"
  total_sent=0; total_ok=0
  for i in $(seq 0 $((N_PARALLEL - 1))); do
    log="$DIR/$i.log"
    sent=$(grep -E "^bundles sent:" "$log" | awk '{print $3}' | tail -1)
    ok=$(grep -E "^bundles ok:" "$log" | awk '{print $3}' | tail -1)
    errpct=$(grep -E "^error rate:" "$log" | awk '{print $3}' | tr -d '%' | tail -1)
    incl=$(grep -E "^inclusion rate:" "$log" | awk '{print $3}' | tr -d '%' | tail -1)
    p50=$(grep "^rpc lat" "$log" | sed -E 's/.*p50=([0-9]+).*/\1/' | tail -1)
    selftps=$(grep "approx user  TPS:" "$log" | awk -F'TPS:' '{print $2}' | tr -d ' ' | tail -1)

    printf "%-4s %-10s %-10s %-8s %-12s %-10s %-10s\n" \
      "$i" "${sent:-?}" "${ok:-?}" "${errpct:-?}" "${incl:-?}" "${p50:-?}" "${selftps:-?}"
    total_sent=$(( total_sent + ${sent:-0} ))
    total_ok=$(( total_ok + ${ok:-0} ))
  done
  echo "-----------------------------------------------------------------"
  printf "%-4s %-10s %-10s\n" "SUM" "$total_sent" "$total_ok"
  echo ""
  echo "聚合 sent / (DURATION_S + DRAIN_S) = $(awk -v s=$total_sent -v d=$((DURATION_S+DRAIN_S)) 'BEGIN{printf "%.1f", s/d}') TPS  (聚合发送速率)"
  echo ""
  echo "=== chain-tps.txt 摘录（去重计数的链上真实 TPS）==="
  cat "$DIR/chain-tps.txt"
  echo ""
  echo "=== 解读 ==="
  echo "1. 如果 SUM sent ≈ TARGET_TOTAL × DURATION_S = $(( TARGET_TOTAL * DURATION_S )) → 客户端达成发送目标"
  echo "2. 如果链上 user TPS 接近 SUM/(DUR+DRAIN) → builder 全消化"
  echo "3. 如果 max_block_txs 接近 60M/21k = 2857 → builder 算力达上限"
  echo "4. 如果 max_block_txs < 1500 但链上 TPS 也低 → builder 内部 simulation/RPC 排队，非算力问题"
} | tee "$SUMMARY"

# 清理
for i in $(seq 0 $((N_PARALLEL - 1))); do
  docker rm -f "fb-spam-multi-$i" 2>/dev/null > /dev/null
done

echo ""
echo "==========================================="
echo "  完成。详细数据："
echo "    cat $SUMMARY"
echo "==========================================="
