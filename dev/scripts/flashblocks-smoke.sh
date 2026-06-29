#!/usr/bin/env bash
# =============================================================================
# flashblocks-smoke.sh — v7 stack 一键端到端冒烟（chain-test2 上跑）
#
# 前置：make dev-up-flashblocks 已成功，4 个新容器都 Up
#
# 跑法：bash dev/scripts/flashblocks-smoke.sh
#       或：make flashblocks-smoke（如果加了 Makefile target，本轮没加）
#
# 验证 9 个关键场景，跑完 ~15s。任意一步失败就 exit 1，让 CI / sign-off 流程
# 能自动判断 v7 部署是否就绪。
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."

# 加载 .env + .env.flashblocks，拿端口
set -a
[[ -f .env ]] && source .env
[[ -f .env.flashblocks ]] && source .env.flashblocks
set +a

: "${BUNDLE_PROXY_PORT:=9560}"
: "${BUNDLE_PROXY_METRICS_PORT:=9561}"
: "${OP_RBUILDER_PORT:=9550}"
: "${FLASHBLOCKS_RPC_PORT:=9548}"
: "${L2_RPC_PORT:=9545}"
: "${L2_CHAIN_ID:=175700}"

# ⚠️ smoke 是本机自检，必须用 127.0.0.1（loopback），不要用 PUBLIC_HOST。
# PUBLIC_HOST 是给团队/钱包外部访问的公网 IP，可能：
#   a) AWS SG 没开新端口（9550/9555/9560/9561）→ curl 全 timeout
#   b) 反代/DNS 还指向另一台机器 → 命中老链拿到老 chainId（实测见过）
# 想从公网验证：SMOKE_HOST=<公网IP> bash scripts/flashblocks-smoke.sh
H="${SMOKE_HOST:-127.0.0.1}"
PROXY="http://${H}:${BUNDLE_PROXY_PORT}"
METRICS="http://${H}:${BUNDLE_PROXY_METRICS_PORT}/metrics"
GETH="http://${H}:${L2_RPC_PORT}"

PASS=0
FAIL=0
RESULTS=()

ok()   { echo "  ✅ $1"; RESULTS+=("ok|$1"); PASS=$((PASS+1)); }
err()  { echo "  ❌ $1"; RESULTS+=("err|$1"); FAIL=$((FAIL+1)); }

echo "============================================"
echo "🧪 v7 Flashblocks stack 端到端 smoke"
echo "  proxy   : $PROXY"
echo "  metrics : $METRICS"
echo "  chainId : $L2_CHAIN_ID"
echo "============================================"

# ============= 1) 容器都 Up =============
echo ""
echo "1) 容器状态（必需）"
need_up=(mychain-op-rbuilder mychain-rollup-boost mychain-bundle-proxy)
for c in "${need_up[@]}"; do
  st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
  if [[ "$st" == "running" ]]; then
    ok "$c is running"
  else
    err "$c status=$st"
  fi
done

# flashblocks-rpc 现在是 optional（v7.0 暂不启），探测一下，不算 fail
HAS_FBRPC=0
if [[ "$(docker inspect -f '{{.State.Status}}' mychain-flashblocks-rpc 2>/dev/null)" == "running" ]]; then
  HAS_FBRPC=1
  ok "mychain-flashblocks-rpc is running (optional profile)"
else
  echo "  ℹ️  mychain-flashblocks-rpc not started (v7.0 默认 profile 不起，跳过相关检查)"
fi

# ============= 2) /healthz =============
echo ""
echo "2) bundle-proxy /healthz"
h=$(curl -s --max-time 3 "$PROXY/healthz" || echo "")
if echo "$h" | grep -q '"status":"ok"'; then
  ok "/healthz returned ok ($h)"
else
  err "/healthz NOT ok: $h"
fi

# ============= 3) /status =============
echo ""
echo "3) bundle-proxy /status (in-flight / circuit / head 快照)"
s=$(curl -s --max-time 3 "$PROXY/status" || echo "")
if echo "$s" | grep -q '"chainId"'; then
  ok "/status returned config ($(echo "$s" | head -c 120)...)"
else
  err "/status invalid: $s"
fi

# ============= 4) eth_chainId =============
echo ""
echo "4) eth_chainId（本地缓存返回，<10ms）"
t0=$(date +%s%3N)
r=$(curl -s --max-time 3 "$PROXY" -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}')
t1=$(date +%s%3N)
expected_hex=$(printf '0x%x' "$L2_CHAIN_ID")
if echo "$r" | grep -q "\"result\":\"$expected_hex\""; then
  ok "eth_chainId returned $expected_hex in $((t1-t0))ms"
else
  err "eth_chainId mismatch: got $r, expected $expected_hex"
fi

# ============= 5) eth_blockNumber 透传 =============
echo ""
echo "5) eth_blockNumber（透传到 op-geth，默认 read target）"
r=$(curl -s --max-time 3 "$PROXY" -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')
if echo "$r" | grep -qE '"result":"0x[0-9a-f]+"'; then
  bn=$(echo "$r" | grep -oE '"result":"0x[0-9a-f]+"' | grep -oE '0x[0-9a-f]+')
  ok "eth_blockNumber returned $bn (= $((bn)))"
else
  err "eth_blockNumber failed: $r"
fi

# ============= 6) /metrics 有数据 =============
echo ""
echo "6) /metrics Prometheus 输出"
m=$(curl -s --max-time 3 "$METRICS" || echo "")
if echo "$m" | grep -q "bundle_proxy_rpc_total"; then
  total=$(echo "$m" | grep -E "^bundle_proxy_rpc_total" | head -3 | tr '\n' ';')
  ok "/metrics OK, sample: $total"
else
  err "/metrics missing bundle_proxy_rpc_total"
fi

# ============= 7) op-rbuilder eth_chainId 直连 =============
echo ""
echo "7) op-rbuilder :$OP_RBUILDER_PORT eth_chainId（不经 bundle-proxy）"
r=$(curl -s --max-time 3 "http://${H}:${OP_RBUILDER_PORT}" -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' || echo "")
if echo "$r" | grep -q "\"result\":\"$expected_hex\""; then
  ok "op-rbuilder chainId=$expected_hex"
else
  err "op-rbuilder unreachable or chainId wrong: $r"
fi

# ============= 8) flashblocks-rpc 直连（如果启用了 optional profile）=============
echo ""
if [[ $HAS_FBRPC -eq 1 ]]; then
  echo "8) flashblocks-rpc :$FLASHBLOCKS_RPC_PORT eth_chainId"
  r=$(curl -s --max-time 3 "http://${H}:${FLASHBLOCKS_RPC_PORT}" -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' || echo "")
  if echo "$r" | grep -q "\"result\":\"$expected_hex\""; then
    ok "flashblocks-rpc chainId=$expected_hex"
  else
    err "flashblocks-rpc unreachable or chainId wrong: $r"
  fi
else
  echo "8) flashblocks-rpc 未启用 (optional)，跳过"
fi

# ============= 9) op-geth chain id（v6 兼容性，sequencer 仍指 v7 chainId 175700）=============
echo ""
echo "9) op-geth :$L2_RPC_PORT eth_chainId（sequencer 角色，应也是 v7=$L2_CHAIN_ID）"
r=$(curl -s --max-time 3 "$GETH" -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' || echo "")
if echo "$r" | grep -q "\"result\":\"$expected_hex\""; then
  ok "op-geth chainId=$expected_hex"
else
  err "op-geth chainId mismatch (op-geth fresh state 没拉？): $r"
fi

# ============= summary =============
echo ""
echo "============================================"
echo "✅ $PASS pass / ❌ $FAIL fail"
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "失败项："
  for r in "${RESULTS[@]}"; do
    [[ "$r" =~ ^err\| ]] && echo "  - ${r#err|}"
  done
  echo ""
  echo "排查指南："
  echo "  make flashblocks-status            # 看容器健康"
  echo "  make flashblocks-logs              # 看 4 容器最近日志"
  echo "  make flashblocks-logs-bundle-proxy # 单独看 bundle-proxy"
  echo "  curl $PROXY/status                 # 看 in-flight/circuit/head"
  echo "  curl $METRICS                      # 看 prom metrics"
  exit 1
fi

echo ""
echo "🚀 v7 stack 端到端就绪。下一步建议："
echo "  - 压测 200 TPS 单档：make bot-token-spam-up TARGET_TPS=200"
echo "  - 端到端 800 TPS 单档：make bot-token-spam-up TARGET_TPS=800"
echo "  - 24h soak (M3 范围): bash scripts/stability-up.sh"
echo "  - reorg 监控（D3=force_d3b 风险量化, PHASE2_INTEGRATION §6.3）："
echo "      docker logs mychain-blockscout-backend 2>&1 | grep -c non_canonical"
exit 0
