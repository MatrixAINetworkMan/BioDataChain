#!/usr/bin/env bash
# ============================================================================
# 在【L1 机】（独立 geth Clique，dev/l1）上运行。
# 测 mychain-l1-geth 重启的「能否恢复 + 会不会丢数据」。
#
#   bash docs/restart-test/l1-restart-test.sh           # R08: docker restart（默认）
#   bash docs/restart-test/l1-restart-test.sh R09       # R09: make down && make up（重建容器，保留卷）
#
# 只做非破坏性重启；绝不 down -v / clean。需要 docker + curl + jq。
# ============================================================================
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$DIR/_lib.sh"
need docker curl jq

L1_DIR="${L1_DIR:-$REPO_ROOT/dev/l1}"
HTTP_PORT="$(envget HTTP_PORT "$L1_DIR/.env")"; HTTP_PORT="${HTTP_PORT:-8545}"
RPC="http://127.0.0.1:${HTTP_PORT}"
C="$(resolve_c mychain-l1-geth)"
[ -z "$C" ] && { say "❌ 找不到容器 mychain-l1-geth，确认在 L1 机上运行"; exit 1; }
CASE="${1:-R08}"
init_run_log

say "===== L1 重启测试 ($CASE) ====="
say "RPC=$RPC  容器=$C  目录=$L1_DIR"

# ---- preflight 基准 ----
CID0=$(cid "$RPC"); GH0=$(ghash "$RPC"); HEAD0=$(bn "$RPC")
say "preflight: chainId=$CID0  genesis=$GH0  head=$HEAD0"
[ "$HEAD0" -le 0 ] 2>/dev/null && { say "❌ 起步 head=$HEAD0，L1 没在正常出块，终止"; exit 1; }

# 找一笔历史 tx（最近 200 块），重启后用来验「历史 tx 仍可查」
BENCH_TX="${BENCH_TX:-}"
if [ -z "$BENCH_TX" ]; then
  for off in $(seq 0 200); do
    n=$((HEAD0-off)); [ "$n" -lt 0 ] && break
    hx=$(printf '0x%x' "$n")
    t=$(rpc "$RPC" "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$hx\",false],\"id\":1}" | jq -r '.result.transactions[0]//empty' 2>/dev/null)
    [ -n "$t" ] && { BENCH_TX="$t"; break; }
  done
fi
say "benchmark L1 tx=${BENCH_TX:-（最近200块无tx，跳过tx校验）}"

# ---- 执行重启 ----
if [ "$CASE" = R09 ]; then
  say ">> make down && make up（重建容器，保留卷）..."
  ( cd "$L1_DIR" && make down && make up ) || say "⚠️ make 执行有非零返回"
else
  say ">> docker restart $C ..."
  docker restart "$C" >/dev/null 2>&1 || say "⚠️ docker restart 非零返回"
fi

# ---- 验收：能否恢复 ----
wait_running "$C" 60 || say "  ⚠️ 容器未稳定 running"
wait_rpc "$RPC" 30 || say "  ⚠️ RPC 30s 内未应答"
EL=$(wait_head "$RPC" "$HEAD0" 60); RC=$?
HEAD1=$(bn "$RPC")
REC=❌; { [ "$RC" -eq 0 ] && [ "$HEAD1" -ge "$HEAD0" ] && [ "$(cstatus "$C")" = running ]; } && REC=✅

# ---- 验收：会不会丢数据（L1 geth 有持久卷）----
GH1=$(ghash "$RPC"); CID1=$(cid "$RPC")
DATA=✅
[ "$GH1" != "$GH0" ] && DATA=❌            # genesis 变 = 链被换/误清
[ "$CID1" != "$CID0" ] && DATA=❌          # chainId 变
[ "$HEAD1" -le 0 ] 2>/dev/null && DATA=❌  # 从 0 起步 = LevelDB 损坏/挂错卷（K8 红线）
TXR=SKIP
if [ -n "$BENCH_TX" ]; then
  r=$(rcpt "$RPC" "$BENCH_TX"); if [ "$r" != null ]; then TXR=OK; else TXR=FAIL; DATA=❌; fi
fi

say "after: head=$HEAD1  genesis=$GH1  chainId=$CID1  benchTx=$TXR  恢复耗时≈${EL}s"
[ "$DATA" = ❌ ] && [ "$HEAD1" -le 0 ] 2>/dev/null && say "🚨 head 从 0 起步！立即停止后续操作，排查 mychain-l1-geth-data 卷是否被误清。"
mark "$CASE" "L1-geth" "$REC" "$DATA" "head $HEAD0→$HEAD1; genesis $([ "$GH1" = "$GH0" ] && echo 不变 || echo 变了!); tx=$TXR; ≈${EL}s"
