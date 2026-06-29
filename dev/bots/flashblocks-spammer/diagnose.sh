#!/usr/bin/env bash
# =============================================================================
# Phase 1.4 拐点根因诊断
#
# 重跑一次 1000 TPS / 30s 同时实时监控所有相关组件，定位瓶颈在：
#   (a) spammer 客户端 (Node.js fetch + signing)
#   (b) op-rbuilder RPC server (reth HTTP queue)
#   (c) op-rbuilder mempool / block building
#   (d) rollup-boost / bproxy 转发
#   (e) host TCP socket / file descriptor
#
# 输出：logs/diagnose-<时间戳>/
#   ├── stats.txt           # docker stats 多次快照（CPU/MEM/NetIO）
#   ├── op-rbuilder.log     # 期间的 op-rbuilder warning/error
#   ├── metrics.txt         # op-rbuilder prometheus metrics 快照（如果暴露）
#   ├── spammer-final.log   # spammer 最终报告 + 错误样本
#   └── summary.md          # 综合诊断结论（人工 review）
#
# 用法：bash diagnose.sh
#   可选环境变量：
#     TARGET_TPS=1500     # 默认 1000
#     DURATION_S=60       # 默认 30
#     SAMPLE_INTERVAL=5   # docker stats 抓取间隔
# =============================================================================
set -uo pipefail
# 故意不加 -e：诊断脚本里大量 `grep | head` 这种短路管道，
# 任意一段 SIGPIPE 就退出会导致 summary.md 永远生成不出来。
# 我们宁可让某段 grep 静默失败，也要保证 summary.md 落盘。

cd "$(dirname "$0")"

TARGET_TPS="${TARGET_TPS:-1000}"
N_SENDERS="${N_SENDERS:-$(( (TARGET_TPS + 3) / 4 ))}"
DURATION_S="${DURATION_S:-30}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
ERR_SAMPLES_MAX="${ERR_SAMPLES_MAX:-50}"

CONTAINERS=(
  renewing-tetra-op-rbuilder-1
  renewing-tetra-rollup-boost-1
  renewing-tetra-bproxy-1
  renewing-tetra-flashblocks-rpc-1
  renewing-tetra-op-geth-1
)

TS=$(date +%Y%m%d-%H%M%S)
DIR="logs/diagnose-$TS"
mkdir -p "$DIR"

echo "==========================================="
echo "  Phase 1.4 拐点根因诊断"
echo "  TARGET_TPS=$TARGET_TPS  N_SENDERS=$N_SENDERS  DURATION_S=$DURATION_S"
echo "  output: $DIR/"
echo "==========================================="

# -----------------------------------------------------------------------------
# Step 0: 基线信息（host 资源 + op-rbuilder RPC 配置）
# -----------------------------------------------------------------------------
{
  echo "=== host 资源 ==="
  echo "CPU cores: $(nproc)"
  echo -n "RAM:       "
  free -h | awk 'NR==2 {print $2 " total, " $7 " available"}'
  echo "ulimit -n: $(ulimit -n)"
  echo ""
  echo "=== op-rbuilder 启动参数（找 RPC limit）==="
  docker inspect renewing-tetra-op-rbuilder-1 --format '{{json .Config.Cmd}}' | jq
  echo ""
  echo "=== op-rbuilder metrics 是否暴露 (port 9090 内, host 9091) ==="
  curl -s --max-time 3 -o /dev/null -w "  HTTP %{http_code}, time=%{time_total}s\n" \
    http://127.0.0.1:9091/metrics || echo "  metrics endpoint 不可达"
} | tee "$DIR/baseline.txt"

# -----------------------------------------------------------------------------
# Step 1: 确保依赖 + 清理旧 spammer
# -----------------------------------------------------------------------------
if [[ ! -d node_modules ]]; then
  echo ""
  echo "=== 安装 npm 依赖（一次性）==="
  docker run --rm -v "$(pwd)":/app -w /app node:20-alpine npm install
fi

docker rm -f fb-spam-diag 2>/dev/null || true

# -----------------------------------------------------------------------------
# Step 2: 启 spammer（后台），同时启 docker stats 采样后台 loop
# -----------------------------------------------------------------------------
echo ""
echo "=== 启 spammer ==="
docker run -d --network host -v "$(pwd)":/app -w /app \
  -e TARGET_TPS="$TARGET_TPS" \
  -e N_SENDERS="$N_SENDERS" \
  -e DURATION_S="$DURATION_S" \
  -e ERR_SAMPLES_MAX="$ERR_SAMPLES_MAX" \
  --name fb-spam-diag \
  node:20-alpine \
  node spammer.js > /dev/null

echo "  spammer container started, sampling every ${SAMPLE_INTERVAL}s..."

# -----------------------------------------------------------------------------
# Step 3: 实时 docker stats 采样
# -----------------------------------------------------------------------------
SAMPLES=$(( (DURATION_S + 10) / SAMPLE_INTERVAL ))
{
  echo "=== docker stats 采样（${SAMPLES} 次，每 ${SAMPLE_INTERVAL}s 一次）==="
  for i in $(seq 1 "$SAMPLES"); do
    sleep "$SAMPLE_INTERVAL"
    echo ""
    echo "--- T+$((i * SAMPLE_INTERVAL))s ---"
    docker stats --no-stream "${CONTAINERS[@]}" fb-spam-diag \
      --format "{{.Name}}\tCPU={{.CPUPerc}}\tMEM={{.MemUsage}}\tNetIO={{.NetIO}}\tBlockIO={{.BlockIO}}" 2>&1 || true
  done
} | tee "$DIR/stats.txt"

# -----------------------------------------------------------------------------
# Step 4: 等 spammer 完成 + 抓最终报告
# -----------------------------------------------------------------------------
echo ""
echo "=== 等 spammer 完成 ==="
docker wait fb-spam-diag > /dev/null 2>&1 || true
docker logs fb-spam-diag 2>&1 | tee "$DIR/spammer-final.log" > /dev/null
echo "  spammer 已结束，日志写到 $DIR/spammer-final.log"

# -----------------------------------------------------------------------------
# Step 5: 抓 op-rbuilder 的 warning/error log
# -----------------------------------------------------------------------------
{
  echo "=== op-rbuilder 期间的 warning/error/reject log（最近 ${DURATION_S}s+）==="
  docker logs --since="$((DURATION_S + 30))s" renewing-tetra-op-rbuilder-1 2>&1 \
    | grep -iE "warn|error|reject|drop|exceed|saturate|limit|over|full|throttl|backoff" \
    | tail -80 \
    || echo "(无 warning/error)"
} | tee "$DIR/op-rbuilder.log"

# -----------------------------------------------------------------------------
# Step 6: 抓 metrics（如果暴露）—— 重点抓影响 1000 TPS 拐点的 RPC/pool/payload 指标
# -----------------------------------------------------------------------------
{
  echo "=== op-rbuilder metrics 快照（关键 RPC / mempool / block 指标）==="
  if curl -s --max-time 3 http://127.0.0.1:9091/metrics > /dev/null 2>&1; then
    METRICS=$(curl -s http://127.0.0.1:9091/metrics)
    echo "--- 关键 RPC 调用计数（过滤 0 值）---"
    echo "$METRICS" | grep "^reth_rpc_server_calls_started_total" | grep -vE "} 0$" || true
    echo ""
    echo "--- 关键 RPC 错误计数 ---"
    echo "$METRICS" | grep -E "^reth_rpc_server_calls_failed_total" | grep -vE "} 0$" || true
    echo ""
    echo "--- mempool / tx pool 相关 ---"
    echo "$METRICS" | grep -E "^reth_(transaction_pool|optimism_transaction_pool)" | grep -vE "} 0$" || true
    echo ""
    echo "--- payload / block building 相关 ---"
    echo "$METRICS" | grep -E "^reth_(payloads|engine|consensus_engine|op_rbuilder)" | grep -vE "} 0$" || true
    echo ""
    echo "--- HTTP 连接 / 资源 ---"
    echo "$METRICS" | grep -E "^reth_rpc_server_(connections|requests)" | grep -vE "} 0$" || true
    echo ""
    echo "--- 进程资源（CPU/RSS/FD）---"
    echo "$METRICS" | grep -E "^process_" || true
  else
    echo "(metrics 不暴露)"
  fi
} > "$DIR/metrics.txt" 2>&1 || true
echo "  metrics 写入 $DIR/metrics.txt"

# -----------------------------------------------------------------------------
# Step 7: 综合 summary（最关键的几个数字）
# -----------------------------------------------------------------------------
{
  echo "# Phase 1.4 拐点根因诊断 summary ($TS)"
  echo ""
  echo "**配置**：TARGET_TPS=$TARGET_TPS  N_SENDERS=$N_SENDERS  DURATION_S=$DURATION_S"
  echo ""
  echo "## spammer 最终报告（关键数字）"
  echo '```'
  grep -E "bundles (sent|ok|err):|error rate:|approx (chain|user) TPS:|max txs in single block:|rpc lat \(ms\):|inclusion rate:" \
    "$DIR/spammer-final.log" | head -10 || true
  echo '```'
  echo ""
  echo "## docker stats 峰值 CPU（哪个容器先饱和）"
  echo '```'
  awk -F'CPU=|%' '/CPU=/{ cpu=$2; gsub(/[^0-9.]/,"",cpu); name=$1; gsub(/[ \t].*/,"",name); if(cpu+0 > peak[name]) peak[name]=cpu } END { for(n in peak) printf "%-50s peak CPU = %s%%\n", n, peak[n] }' \
    "$DIR/stats.txt" | sort -k5 -nr || true
  echo '```'
  echo ""
  echo "## error 样本（只取前 10）"
  echo '```'
  grep -A1 "error samples:" "$DIR/spammer-final.log" | head -20 || true
  echo '```'
  echo ""
  echo "## op-rbuilder warning/error 出现次数"
  echo '```'
  grep -ciE "warn|error|reject|drop|saturate|full" "$DIR/op-rbuilder.log" || echo "0"
  echo '```'
  echo ""
  echo "## 文件清单"
  ls -la "$DIR/"
} > "$DIR/summary.md"

# -----------------------------------------------------------------------------
# Step 8: 清理
# -----------------------------------------------------------------------------
docker rm -f fb-spam-diag > /dev/null 2>&1 || true

echo ""
echo "==========================================="
echo "  完成。重点看："
echo "    cat $DIR/summary.md"
echo "    cat $DIR/stats.txt    (docker stats 采样)"
echo "    cat $DIR/op-rbuilder.log"
echo "==========================================="
