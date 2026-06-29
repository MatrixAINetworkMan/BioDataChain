#!/usr/bin/env bash
# ============================================================================
# 在【链机】（op-geth/op-node/op-batcher/op-proposer/Flashblocks三件套/l1-proxy/
# bundle-proxy，dev/）上运行。逐个容器 docker restart，验「能否恢复 + 会不会丢数据」。
#
#   bash docs/restart-test/chain-restart-test.sh                 # 跑全部安全用例
#   bash docs/restart-test/chain-restart-test.sh R03 R02         # 只跑指定用例
#   SMOKE=0 bash docs/restart-test/chain-restart-test.sh         # 跳过结尾 flashblocks-smoke
#
# 用例：R01 l1-proxy / R02 op-geth* / R03 op-rbuilder* / R04 rollup-boost(单点) /
#       R05 op-node / R06 op-batcher / R06b op-proposer / R07 bundle-proxy
#   （* = 有持久卷，需测数据无损；其余无状态，数据列 N/A）
#
# 只做 docker restart（非破坏性）；绝不 down -v / flashblocks-clean。
# 若 rollup-boost / op-node 重启后卡住，脚本只提示，不自动 recover（除非 AUTO_RECOVER=1）。
# ============================================================================
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$DIR/_lib.sh"
need docker curl jq

CHAIN_DIR="${CHAIN_DIR:-$REPO_ROOT/dev}"
P_GETH="$(envget L2_RPC_PORT "$CHAIN_DIR/.env")";        GETH="http://127.0.0.1:${P_GETH:-9545}"
P_RB="$(envget OP_RBUILDER_PORT "$CHAIN_DIR/.env")";     RBUILDER="http://127.0.0.1:${P_RB:-9550}"
P_PROXY="$(envget BUNDLE_PROXY_PORT "$CHAIN_DIR/.env")"; PROXY="http://127.0.0.1:${P_PROXY:-9560}"
P_NODE="$(envget OP_NODE_RPC_PORT "$CHAIN_DIR/.env")";   OPNODE="http://127.0.0.1:${P_NODE:-9547}"
init_run_log

# 重启某容器时，用哪个 RPC 观察“链是否在涨”（被重启的那路自己会断，要看另一路）
headsrc(){ case "$1" in *op-geth*) echo "$RBUILDER";; *) echo "$GETH";; esac; }
proxy_circuit(){ curl -s --max-time 3 "$PROXY/status" | jq -r '.circuit//"?"' 2>/dev/null || echo "?"; }

say "===== 链机重启测试 ====="
say "op-geth=$GETH  op-rbuilder=$RBUILDER  bundle-proxy=$PROXY  op-node=$OPNODE"

# 全局基准（用于有状态模块的数据无损比对）
GH0=$(ghash "$GETH"); CID0=$(cid "$GETH")
say "preflight: L2 chainId=$CID0  genesis=$GH0  head(geth)=$(bn "$GETH")  head(rbuilder)=$(bn "$RBUILDER")  circuit=$(proxy_circuit)"
# 历史 L2 tx（最近 50 块），验 op-geth 数据无损用
H0=$(bn "$GETH"); BENCH_TX="${BENCH_TX:-}"
if [ -z "$BENCH_TX" ] && [ "$H0" -gt 0 ] 2>/dev/null; then
  for off in $(seq 0 50); do n=$((H0-off)); [ "$n" -lt 0 ] && break
    hx=$(printf '0x%x' "$n")
    t=$(rpc "$GETH" "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$hx\",false],\"id\":1}" | jq -r '.result.transactions[0]//empty' 2>/dev/null)
    [ -n "$t" ] && { BENCH_TX="$t"; break; }
  done
fi
say "benchmark L2 tx=${BENCH_TX:-（无，跳过 tx 校验）}"

# run_case <case> "<容器候选名...>" <module> <stateful 0/1> <module_rpc> <timeout>
run_case(){
  local case=$1 cands=$2 mod=$3 stateful=$4 mrpc=$5 timeout=${6:-60}
  local C; C=$(resolve_c $cands)
  if [ -z "$C" ]; then mark "$case" "$mod" "⏭" "⏭" "容器不存在($cands)，跳过"; return; fi
  say ">> $case  重启 $C  ($mod)"
  local src base; src=$(headsrc "$C"); base=$(bn "$src")
  docker restart "$C" >/dev/null 2>&1 || say "  ⚠️ docker restart 非零返回"
  wait_running "$C" "$timeout" || say "  ⚠️ $C 未稳定 running"
  local el rc; el=$(wait_head "$src" "$base" "$timeout"); rc=$?
  local REC=❌; { [ "$rc" -eq 0 ] && [ "$(cstatus "$C")" = running ]; } && REC=✅

  local DATA="N/A"
  if [ "$stateful" = 1 ]; then
    wait_rpc "$mrpc" 30 || say "  ⚠️ $mod RPC 30s 内未应答"
    local gh ch hd; gh=$(ghash "$mrpc"); ch=$(cid "$mrpc"); hd=$(bn "$mrpc")
    DATA=✅
    [ "$gh" != "$GH0" ] && DATA=❌
    [ "$ch" != "$CID0" ] && DATA=❌
    [ "$hd" -le 0 ] 2>/dev/null && DATA=❌
    if [ "$mod" = op-geth ] && [ -n "$BENCH_TX" ]; then
      [ "$(rcpt "$mrpc" "$BENCH_TX")" = null ] && DATA=❌
    fi
    say "  data: genesis=$([ "$gh" = "$GH0" ] && echo ok || echo MISMATCH!)  head=$hd"
  fi

  # 卡死提示（单点 / 启动顺序）
  if [ "$REC" = ❌ ]; then
    say "  🚨 $mod 重启后链未恢复涨块。修复：cd $CHAIN_DIR && make flashblocks-recover"
    if [ "${AUTO_RECOVER:-0}" = 1 ]; then say "  >> AUTO_RECOVER=1，执行 flashblocks-recover"; ( cd "$CHAIN_DIR" && make flashblocks-recover ); fi
  fi
  mark "$case" "$mod" "$REC" "$DATA" "恢复≈${el}s; circuit=$(proxy_circuit)"
}

dispatch(){ case "$1" in
  R01)  run_case R01  "l1-proxy mychain-l1-proxy"     l1-proxy      0 "" 60 ;;
  R06)  run_case R06  "mychain-op-batcher"            op-batcher    0 "" 60 ;;
  R06b) run_case R06b "mychain-op-proposer"           op-proposer   0 "" 60 ;;
  R07)  run_case R07  "mychain-bundle-proxy"          bundle-proxy  0 "" 60 ;;
  R03)  run_case R03  "mychain-op-rbuilder"           op-rbuilder   1 "$RBUILDER" 90 ;;
  R02)  run_case R02  "mychain-op-geth"               op-geth       1 "$GETH"     90 ;;
  R05)  run_case R05  "mychain-op-node"               op-node       0 "" 90 ;;
  R04)  run_case R04  "mychain-rollup-boost"          rollup-boost  0 "" 120 ;;
  *)    say "未知用例: $1（可选 R01 R02 R03 R04 R05 R06 R06b R07）" ;;
esac; }

# 默认顺序：从最不影响链的开始，单点 rollup-boost 放最后
CASES=("$@"); [ ${#CASES[@]} -eq 0 ] && CASES=(R01 R06 R06b R07 R03 R02 R05 R04)
for c in "${CASES[@]}"; do dispatch "$c"; done

# 结尾冒烟
if [ "${SMOKE:-1}" = 1 ] && grep -q flashblocks-smoke "$CHAIN_DIR/Makefile" 2>/dev/null; then
  say ">> make flashblocks-smoke"; ( cd "$CHAIN_DIR" && make flashblocks-smoke ) || say "⚠️ smoke 未全过，检查上面输出"
fi
say "✅ 完成。结果见 $RUN_LOG"
