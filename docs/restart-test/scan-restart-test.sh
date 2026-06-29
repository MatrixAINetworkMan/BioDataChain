#!/usr/bin/env bash
# ============================================================================
# 在【浏览器机】（dev/blockscout-standalone）上运行。
# 测 Blockscout 重启的「能否恢复 + 会不会丢数据」。
#
#   bash docs/restart-test/scan-restart-test.sh
#
# Blockscout 索引为非权威数据（丢了能从链 re-index 重建），故数据列标 ✅(可重建)。
# 只做 docker compose restart（非破坏性）；绝不 down -v。需要 docker + curl + jq。
# ============================================================================
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$DIR/_lib.sh"
need docker curl jq

SCAN_DIR="${SCAN_DIR:-$REPO_ROOT/dev/blockscout-standalone}"
[ -d "$SCAN_DIR" ] || { say "❌ 找不到目录 $SCAN_DIR（确认在浏览器机上运行，或设 SCAN_DIR=）"; exit 1; }
API_PORT="$(envget BLOCKSCOUT_API_PORT "$SCAN_DIR/.env")"; API_PORT="${API_PORT:-4001}"
API="http://127.0.0.1:${API_PORT}"
init_run_log

bsblock(){ curl -s --max-time 5 "$API/api/v2/blocks?limit=1" | jq -r '.items[0].height//-1' 2>/dev/null || echo -1; }

say "===== 浏览器机 Blockscout 重启测试 (BS1) ====="
say "API=$API  目录=$SCAN_DIR"
B0=$(bsblock); say "preflight: blockscout 最新块=$B0"

say ">> docker compose restart ..."
( cd "$SCAN_DIR" && docker compose restart ) || say "⚠️ docker compose restart 非零返回"

# 能否恢复：API 30~90s 内可达
OK=0; i=0; while [ "$i" -lt 90 ]; do b=$(bsblock); if [ "$b" -ge 0 ] 2>/dev/null; then OK=1; break; fi; sleep 3; i=$((i+3)); done
B1=$(bsblock)
# 块号是否继续涨（最多等 60s）
j=0; while [ "$j" -lt 60 ]; do b=$(bsblock); if [ "$b" -gt "$B0" ] 2>/dev/null; then break; fi; sleep 3; j=$((j+3)); done
B2=$(bsblock)

REC=❌; { [ "$OK" = 1 ] && [ "$B2" -ge "$B0" ] 2>/dev/null; } && REC=✅
# 数据：API 回来且块号没异常归零即视为索引保留；本质可重建
DATA="✅(可重建)"; { [ "$OK" != 1 ] || { [ "$B1" -ge 0 ] 2>/dev/null && [ "$B1" -lt $((B0/2)) ] 2>/dev/null; }; } && DATA="⚠️(在重建索引)"

say "after: 块号 $B0→$B2  API=$([ "$OK" = 1 ] && echo 可达 || echo 不可达)"
mark BS1 Blockscout "$REC" "$DATA" "height $B0→$B2; API恢复≈${i}s"
say "✅ 完成。结果见 $RUN_LOG"
