#!/usr/bin/env bash
# 公共函数库，被 l1/chain/scan 三个脚本 source。不要直接运行。

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
RUN_LOG="${RUN_LOG:-$REPO_ROOT/docs/RESTART_TEST_RUN_$(date +%F).md}"

need(){ for b in "$@"; do command -v "$b" >/dev/null 2>&1 || { echo "❌ 缺少命令: $b"; exit 1; }; done; }
say(){ printf '%s\n' "$*"; }
hr(){ printf -- '------------------------------------------------------------\n'; }

# 从 .env 安全取值（不 source，避开含空格/特殊字符的行）
envget(){ grep -E "^$1=" "$2" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"'"'\r'; }

# --- RPC 探针（纯 curl + jq）---
rpc(){ curl -s --max-time 5 -X POST "$1" -H 'content-type: application/json' -d "$2" 2>/dev/null; }
bn(){ local h; h=$(rpc "$1" '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq -r '.result//empty' 2>/dev/null)
      if [[ $h =~ ^0x[0-9a-fA-F]+$ ]]; then echo $((h)); else echo -1; fi; }
cid(){ rpc "$1" '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' | jq -r '.result//"ERR"' 2>/dev/null; }
ghash(){ rpc "$1" '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' | jq -r '.result.hash//"ERR"' 2>/dev/null; }
rcpt(){ rpc "$1" "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$2\"],\"id\":1}" | jq -r '.result.blockNumber//"null"' 2>/dev/null; }

# --- docker 探针 ---
cstatus(){ docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo missing; }
resolve_c(){ local c; for c in "$@"; do docker inspect "$c" >/dev/null 2>&1 && { echo "$c"; return 0; }; done; echo ""; return 1; }

# 等容器稳定 running，最多 $2 秒
wait_running(){ local c=$1 t=${2:-60} i=0; while [ "$i" -lt "$t" ]; do
    if [ "$(cstatus "$c")" = running ]; then sleep 2; [ "$(cstatus "$c")" = running ] && return 0; fi
    sleep 1; i=$((i+1)); done; return 1; }

# 等 RPC 可应答（chainId 非 ERR），最多 $2 秒
wait_rpc(){ local u=$1 t=${2:-30} i=0; while [ "$i" -lt "$t" ]; do
    [ "$(cid "$u")" != ERR ] && return 0; sleep 1; i=$((i+1)); done; return 1; }

# 等 bn($1) > $2，最多 $3 秒；stdout 打印用时秒数
wait_head(){ local url=$1 base=$2 t=${3:-60} i=0 cur; while [ "$i" -lt "$t" ]; do
    cur=$(bn "$url"); if [ "$cur" -gt "$base" ] 2>/dev/null; then echo "$i"; return 0; fi
    sleep 1; i=$((i+1)); done; echo "$i"; return 1; }

init_run_log(){ if [ ! -f "$RUN_LOG" ]; then
    printf '# RESTART_TEST_RUN %s\n\n> 每行一个用例实跑结果。可恢复/数据无损 = ✅/❌/⏭(跳过)/N/A\n\n| 时间 | 用例 | 模块 | 可恢复 | 数据无损 | 备注 |\n|---|---|---|:---:|:---:|---|\n' "$(date +%F)" > "$RUN_LOG"
    say "📝 新建结果文件: $RUN_LOG"; fi; }

# 记一行结果：mark <case> <module> <recover> <dataloss> <note>
mark(){ local c=$1 m=$2 r=$3 d=$4 note=${5:-}
  hr; say "RESULT  $c  [$m]   可恢复=$r   数据无损=$d   $note"; hr
  printf '| %s | %s | %s | %s | %s | %s |\n' "$(date +%T)" "$c" "$m" "$r" "$d" "$note" >> "$RUN_LOG"; }
