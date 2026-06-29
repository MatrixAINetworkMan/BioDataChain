#!/usr/bin/env bash
# =============================================================================
# flashblocks-port-check.sh — v7 stack 公网端口可达性自检
#
# 用途：从一台主机（最好是外部机器）测试 chain-test2 公网 IP 上 v7 stack 需要
# 暴露的端口是否都开了。结果分组，缺哪个一目了然，--ticket 可直接生成
# 给运维同事的工单 markdown。
#
# 跑法：
#   bash dev/scripts/flashblocks-port-check.sh                      # 默认用 .env 的 PUBLIC_HOST
#   bash dev/scripts/flashblocks-port-check.sh --host 1.2.3.4
#   bash dev/scripts/flashblocks-port-check.sh --ticket             # 末尾输出工单 md
#   bash dev/scripts/flashblocks-port-check.sh --show-private       # 也查"应该关"的端口
#
# 端口分组（按角色）：
#   GROUP A — dApp / SDK 入口         （必须开，不开 v7 上线就废）
#   GROUP B — Blockscout 浏览器       （必须开，用户体验）
#   GROUP C — 调试 / 监控             （可选，建议限内网）
#   GROUP D — 仅容器间内部用          （必须关，开 = 安全风险）
#
# 探测策略：
#   1) TCP 通断：bash /dev/tcp 内置探测，3s timeout
#   2) RPC 端口额外查 eth_chainId，验证 == 175700（命中老链会被识别）
#   3) bundle-proxy 额外查 /healthz；/metrics 额外查 prom 字段
#
# 退出码：
#   0  全部 OK（或只有 optional 缺）
#   1  必须开的端口缺失
#   2  参数错或环境错
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."

# 加载 .env + .env.flashblocks 拿端口和 PUBLIC_HOST
set -a
[[ -f .env ]] && source .env
[[ -f .env.flashblocks ]] && source .env.flashblocks
set +a

: "${ANVIL_PORT:=8545}"
: "${L2_RPC_PORT:=9545}"
: "${L2_WS_PORT:=9546}"
: "${OP_NODE_RPC_PORT:=9547}"
: "${OP_RBUILDER_PORT:=9550}"
: "${OP_RBUILDER_FB_WS_PORT:=9551}"
: "${ROLLUP_BOOST_PORT:=9555}"
: "${FLASHBLOCKS_RPC_PORT:=9548}"
: "${BUNDLE_PROXY_PORT:=9560}"
: "${BUNDLE_PROXY_METRICS_PORT:=9561}"
: "${BLOCKSCOUT_PORT:=4000}"
: "${BLOCKSCOUT_API_PORT:=4001}"
: "${BLOCKSCOUT_STATS_PORT:=4002}"
: "${PROMETHEUS_PORT:=9090}"
: "${GRAFANA_PORT:=3000}"
: "${L2_CHAIN_ID:=175700}"

# ===== 参数 =====
H="${PUBLIC_HOST:-}"
SHOW_PRIVATE=0
EXPORT_TICKET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)         H="$2"; shift 2 ;;
    --show-private) SHOW_PRIVATE=1; shift ;;
    --ticket)       EXPORT_TICKET=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "未知参数：$1（看 --help）" >&2; exit 2 ;;
  esac
done

if [[ -z "$H" ]]; then
  echo "❌ PUBLIC_HOST 未设置且未传 --host" >&2
  echo "   方法 1：在 dev/.env 配置 PUBLIC_HOST=<公网IP或域名>" >&2
  echo "   方法 2：bash $(basename "$0") --host <ip-or-domain>" >&2
  exit 2
fi

EXPECTED_CHAIN_HEX=$(printf '0x%x' "$L2_CHAIN_ID")

# ===== probes =====
# TCP 探测（bash /dev/tcp，不依赖 nc/ncat）
probe_tcp() {
  local h=$1 p=$2
  if timeout 3 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null; then
    exec 3<&- 3>&- 2>/dev/null || true
    return 0
  fi
  return 1
}

# RPC chainId 探测：echo "<detail>"; 返回 0=ok 1=mismatch 2=no-rpc
probe_rpc_chainid() {
  local url=$1
  local r
  r=$(curl -s --max-time 3 "$url" -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' 2>/dev/null || echo "")
  if [[ -z "$r" ]]; then
    echo "TCP 通但 RPC 无响应"
    return 2
  fi
  if echo "$r" | grep -q "\"result\":\"$EXPECTED_CHAIN_HEX\""; then
    echo "chainId=$EXPECTED_CHAIN_HEX ✓"
    return 0
  fi
  local got
  got=$(echo "$r" | grep -oE '"result":"0x[0-9a-fA-F]+"' | head -1 | grep -oE '0x[0-9a-fA-F]+' || true)
  echo "chainId=${got:-?} ≠ $EXPECTED_CHAIN_HEX（指向别的链 / 反代错）"
  return 1
}

probe_healthz() {
  local r
  r=$(curl -s --max-time 3 "$1/healthz" 2>/dev/null || echo "")
  if echo "$r" | grep -q '"status":"ok"'; then
    echo "/healthz ok"
    return 0
  fi
  echo "/healthz 异常: ${r:0:60}"
  return 1
}

probe_metrics() {
  local r
  r=$(curl -s --max-time 3 "$1" 2>/dev/null || echo "")
  if echo "$r" | grep -q "^bundle_proxy_rpc_total"; then
    echo "Prom OK ($(echo "$r" | grep -c '^bundle_proxy_') 行 bundle_proxy_*)"
    return 0
  fi
  echo "Prom 字段缺失"
  return 1
}

probe_http_code() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1" 2>/dev/null || echo "000")
  echo "HTTP $code"
  [[ "$code" =~ ^(2|3) ]] && return 0 || return 1
}

# ===== 结果累积 =====
MISSING_MUST=()
MISSING_OPT=()
LEAK=()

row() {
  printf "  %s %5d/tcp  %-32s %s\n" "$1" "$2" "$3" "$4"
}

# check_port <port> <role-label> <group A|B|C|D> <kind tcp|rpc|healthz|metrics|http> <must|optional|leak>
check_port() {
  local port=$1 role=$2 group=$3 kind=$4 imp=$5

  if ! probe_tcp "$H" "$port"; then
    case "$imp" in
      must)
        row "❌" "$port" "$role" "closed / blocked → 必须开"
        MISSING_MUST+=("$port|$role|$group")
        ;;
      optional)
        row "❌" "$port" "$role" "closed / blocked"
        MISSING_OPT+=("$port|$role|$group")
        ;;
      leak)
        row "✅" "$port" "$role" "closed（正确，不该暴露）"
        ;;
    esac
    return
  fi

  # TCP 通了，按 kind 做应用层验证
  local detail rc=0
  case "$kind" in
    rpc)        detail=$(probe_rpc_chainid "http://${H}:${port}"); rc=$? ;;
    healthz)    detail=$(probe_healthz     "http://${H}:${port}"); rc=$? ;;
    metrics)    detail=$(probe_metrics     "http://${H}:${port}/metrics"); rc=$? ;;
    http)       detail=$(probe_http_code   "http://${H}:${port}"); rc=$? ;;
    tcp|*)      detail="TCP open"; rc=0 ;;
  esac

  if [[ "$imp" == "leak" ]]; then
    row "🚨" "$port" "$role" "open（不该暴露 → 安全风险）"
    LEAK+=("$port|$role")
    return
  fi

  if [[ $rc -eq 0 ]]; then
    row "✅" "$port" "$role" "$detail"
  else
    row "⚠️ " "$port" "$role" "$detail"
    # 协议层异常但 TCP 通了，仍当成 missing（dApp 实际跑不起来）
    if [[ "$imp" == "must" ]]; then
      MISSING_MUST+=("$port|$role|$group")
    else
      MISSING_OPT+=("$port|$role|$group")
    fi
  fi
}

# ===== header =====
echo "════════════════════════════════════════════════════════════════════════"
echo "🔍 v7 Flashblocks stack 公网端口可达性检查"
echo "   Target  : $H"
echo "   chainId : $L2_CHAIN_ID ($EXPECTED_CHAIN_HEX)"
echo ""
echo "   ℹ️  本机跑测的是 hairpin NAT 后的可达性。最稳是再从一台**外部机器**"
echo "      （笔记本 / 家网）跑同一脚本对比：bash $(basename "$0") --host $H"
echo "════════════════════════════════════════════════════════════════════════"

# ===== GROUP A =====
echo ""
echo "─── GROUP A · dApp / SDK 入口（必须开，dApp 走这里发交易） ─────────────"
check_port "$BUNDLE_PROXY_PORT" "bundle-proxy 主入口 (dApp)"  A healthz must
check_port "$L2_RPC_PORT"       "op-geth L2 JSON-RPC"          A rpc     must
check_port "$L2_WS_PORT"        "op-geth WebSocket"            A tcp     must

# ===== GROUP B =====
echo ""
echo "─── GROUP B · Blockscout 浏览器（必须开，用户体验） ────────────────────"
check_port "$BLOCKSCOUT_PORT"       "Blockscout 前端 (浏览器入口)" B http must
check_port "$BLOCKSCOUT_API_PORT"   "Blockscout 后端 API"          B http must
check_port "$BLOCKSCOUT_STATS_PORT" "Blockscout stats (图表)"      B http must

# ===== GROUP C =====
echo ""
echo "─── GROUP C · 调试 / 监控（可选，建议限内网） ──────────────────────────"
check_port "$BUNDLE_PROXY_METRICS_PORT" "bundle-proxy /metrics"   C metrics optional
check_port "$OP_RBUILDER_PORT"          "op-rbuilder 直连 RPC"    C rpc     optional
check_port "$ROLLUP_BOOST_PORT"         "rollup-boost 调试 RPC"   C tcp     optional
check_port "$PROMETHEUS_PORT"           "Prometheus"              C tcp     optional
check_port "$GRAFANA_PORT"              "Grafana"                 C tcp     optional

# ===== GROUP D（leak check）=====
if [[ $SHOW_PRIVATE -eq 1 ]]; then
  echo ""
  echo "─── GROUP D · 仅内部（不该暴露！开了 = 安全风险） ──────────────────────"
  check_port "$ANVIL_PORT"            "anvil L1 RPC (内部)"      D tcp leak
  check_port "$OP_NODE_RPC_PORT"      "op-node RPC (内部)"       D tcp leak
  check_port "$OP_RBUILDER_FB_WS_PORT" "op-rbuilder FB WS (内部)" D tcp leak
fi

# ===== summary =====
echo ""
echo "════════════════════════════════════════════════════════════════════════"

if [[ ${#MISSING_MUST[@]} -eq 0 && ${#MISSING_OPT[@]} -eq 0 && ${#LEAK[@]} -eq 0 ]]; then
  echo "✅ 所有需要的端口都已开放，没有暴露不该开的端口。"
  exit 0
fi

if [[ ${#MISSING_MUST[@]} -gt 0 ]]; then
  echo "❌ 【必须开】缺失的端口 (${#MISSING_MUST[@]} 个，不开 v7 上线就废)："
  for it in "${MISSING_MUST[@]}"; do
    IFS='|' read -r p r g <<<"$it"
    printf "   - %5s/tcp  %s  [Group %s]\n" "$p" "$r" "$g"
  done
fi

if [[ ${#MISSING_OPT[@]} -gt 0 ]]; then
  echo ""
  echo "⚠️ 【建议开】缺失的端口 (${#MISSING_OPT[@]} 个，调试 / 监控)："
  for it in "${MISSING_OPT[@]}"; do
    IFS='|' read -r p r g <<<"$it"
    printf "   - %5s/tcp  %s  [Group %s]\n" "$p" "$r" "$g"
  done
fi

if [[ ${#LEAK[@]} -gt 0 ]]; then
  echo ""
  echo "🚨 【安全告警】不该暴露的端口反而开了 (${#LEAK[@]} 个)，找运维**关掉**："
  for it in "${LEAK[@]}"; do
    IFS='|' read -r p r <<<"$it"
    printf "   - %5s/tcp  %s\n" "$p" "$r"
  done
fi

# ===== ticket export =====
if [[ $EXPORT_TICKET -eq 1 ]]; then
  echo ""
  echo "════════════════════════════════════════════════════════════════════════"
  echo "📨 给运维同事的工单（markdown，直接复制粘贴）"
  echo "════════════════════════════════════════════════════════════════════════"
  cat <<EOF

---
## 申请：mychain v7 stack 安全组 / 防火墙开放端口

- **主机**：\`$H\`
- **链**：mychain L2 v7（chainId=\`$L2_CHAIN_ID\`）
- **背景**：v7 Flashblocks 部署完成，现需对外暴露 dApp / 浏览器入口端口

### 必须开 — 入站 TCP

| Port | 用途 | 建议 Source | 说明 |
|------|------|-------------|------|
EOF
  for it in "${MISSING_MUST[@]}"; do
    IFS='|' read -r p r g <<<"$it"
    src="0.0.0.0/0"
    note=""
    case "$g" in
      A) note="dApp / 钱包 / SDK 走这里" ;;
      B) note="用户浏览器访问区块浏览器" ;;
    esac
    printf "| %-4s | %s | %s | %s |\n" "$p" "$r" "$src" "$note"
  done

  if [[ ${#MISSING_OPT[@]} -gt 0 ]]; then
    cat <<EOF

### 建议开 — 入站 TCP（限内网 / 监控网段）

| Port | 用途 | 建议 Source | 说明 |
|------|------|-------------|------|
EOF
    for it in "${MISSING_OPT[@]}"; do
      IFS='|' read -r p r g <<<"$it"
      printf "| %-4s | %s | 内网 / 监控网段 | 仅团队内部调试用 |\n" "$p" "$r"
    done
  fi

  cat <<EOF

### ⚠️ 注意：以下端口**不要**暴露到公网

以下是开发 / 容器内通信端口，开公网 = 被探活脚本攻击：

- \`$ANVIL_PORT\` (anvil L1 RPC) — 仅 op-node / op-batcher 容器用
- \`$OP_NODE_RPC_PORT\` (op-node RPC) — 仅本机调试用
- \`$OP_RBUILDER_FB_WS_PORT\` (op-rbuilder Flashblocks WS) — 仅 flashblocks-rpc 订阅，dApp 不需要

### 验证方法

运维侧改完后，在我这边跑：
\`\`\`bash
bash dev/scripts/flashblocks-port-check.sh
\`\`\`
应该输出"✅ 所有需要的端口都已开放"。

---
EOF
fi

# 必须开有缺失 → exit 1（CI 会卡）
[[ ${#MISSING_MUST[@]} -gt 0 ]] && exit 1
exit 0
