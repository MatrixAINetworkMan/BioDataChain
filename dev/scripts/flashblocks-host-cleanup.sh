#!/usr/bin/env bash
# =============================================================================
# flashblocks-host-cleanup.sh — 清理 host 上占着 mychain 端口的孤立容器/进程
#
# 用途：v6 起不来 "port is already allocated" 时跑这个，
#       自动识别占用者是不是"实验残留"，如是给清理建议或直接清。
#
# 跑法：bash dev/scripts/flashblocks-host-cleanup.sh [--auto-stop]
#
# --auto-stop : 既 stop+rm 非 mychain-* 容器，也 kill 实验残留 host 进程。
#               白名单进程：anvil / reth / op-rbuilder / op-geth / op-node /
#                          op-batcher / rollup-boost / flashblocks-rpc /
#                          bundle-proxy (node) / builder-playground
#
# 安全保证：只 kill 命令行匹配白名单的进程；ssh / cursor / nginx / sshd /
#           systemd 等基础设施进程绝对不动（也匹配不到端口，所以本来就不在范围）。
# =============================================================================
set -uo pipefail

AUTO_STOP=0
[[ "${1:-}" == "--auto-stop" ]] && AUTO_STOP=1

# 进程白名单（cmdline 匹配 → 视为实验残留，可以 kill）
# 这里用 grep -E 的 regex，匹配 ps comm 字段或 args 字段
KILLABLE_PROC_REGEX='anvil|^reth$|reth-bin|op-rbuilder|op-geth|op-node|op-batcher|rollup-boost|flashblocks-rpc|builder-playground|node.*bundle-proxy'

cd "$(dirname "$0")/.."

set -a
[[ -f .env ]] && source .env
[[ -f .env.flashblocks ]] && source .env.flashblocks
set +a

ANVIL_PORT=${ANVIL_PORT:-8545}
L2_RPC_PORT=${L2_RPC_PORT:-9545}
L2_WS_PORT=${L2_WS_PORT:-9546}
OP_RBUILDER_PORT=${OP_RBUILDER_PORT:-9550}
ROLLUP_BOOST_PORT=${ROLLUP_BOOST_PORT:-9555}
FLASHBLOCKS_RPC_PORT=${FLASHBLOCKS_RPC_PORT:-9548}
BUNDLE_PROXY_PORT=${BUNDLE_PROXY_PORT:-9560}
BUNDLE_PROXY_METRICS_PORT=${BUNDLE_PROXY_METRICS_PORT:-9561}

MYCHAIN_PORTS=(
  $ANVIL_PORT
  $L2_RPC_PORT
  $L2_WS_PORT
  $OP_RBUILDER_PORT
  $ROLLUP_BOOST_PORT
  $FLASHBLOCKS_RPC_PORT
  $BUNDLE_PROXY_PORT
  $BUNDLE_PROXY_METRICS_PORT
)

echo "============================================"
echo "🧹 mychain host 端口冲突清理"
echo "  mode: $([[ $AUTO_STOP -eq 1 ]] && echo 'AUTO-STOP（会停 docker 容器）' || echo 'DRY-RUN（只列出，不动）')"
echo "============================================"

# 1. 列出占用 mychain 关键端口的所有容器
echo ""
echo "1) docker 中绑 mychain 端口的容器（任何名字）"
hits_total=0
declare -a TO_KILL=()
for port in "${MYCHAIN_PORTS[@]}"; do
  # 用 docker ps -a 同时匹配 host:port 和 host:port:port 形式
  hits=$(docker ps -a --format "{{.Names}}|{{.Ports}}|{{.Status}}" 2>/dev/null | \
    grep -E "([0-9.]+:|:)?${port}->" || true)
  if [[ -n "$hits" ]]; then
    while IFS='|' read -r name ports status; do
      [[ -z "$name" ]] && continue
      tag=""
      if [[ "$name" =~ ^mychain- ]]; then
        tag="(mychain-，正常)"
      else
        tag="⚠️  非 mychain-，疑似孤儿"
        TO_KILL+=("$name")
      fi
      printf "  port %-5s %s\n    name=%s\n    ports=%s\n    status=%s\n" \
        "$port" "$tag" "$name" "$ports" "$status"
      hits_total=$((hits_total+1))
    done <<< "$hits"
  fi
done

if [[ $hits_total -eq 0 ]]; then
  echo "  ✅ 所有 mychain 端口都没被 docker 容器占用"
fi

# 2. 看 host 进程（非 docker）占了关键端口，自动分析每个进程
echo ""
echo "2) host 进程（非 docker-proxy）占 mychain 端口"
declare -a HOST_TO_KILL=()
declare -a HOST_TO_KEEP=()

# ss 是不是 root 跑的？没 root 看不到 user/pid，提示一下
SS_TEST=$(ss -ltnp 2>/dev/null | head -2)
NEED_SUDO=0
if ! echo "$SS_TEST" | grep -q "users:"; then
  # 普通用户跑 ss 拿不到 users:(("anvil",pid=xxx,fd=xx))，提示
  NEED_SUDO=1
fi

if [[ $NEED_SUDO -eq 1 ]]; then
  echo "  ℹ️  当前非 root，ss 看不到进程 PID/cmd。尝试 sudo -n ..."
  if sudo -n true 2>/dev/null; then
    SS_CMD="sudo -n ss -ltnp 2>/dev/null"
    echo "  ✅ sudo -n OK，能拿到 PID"
  else
    echo "  ⚠️  sudo -n 失败（需要密码）。host 进程分析不完整。"
    echo "      要完整诊断/清理，重跑：sudo bash $0 ${1:-}"
    SS_CMD="ss -ltnp 2>/dev/null"
  fi
else
  SS_CMD="ss -ltnp 2>/dev/null"
fi

host_hits=0
for port in "${MYCHAIN_PORTS[@]}"; do
  ss_line=$(eval "$SS_CMD" | grep ":${port} " | head -1 || true)
  [[ -z "$ss_line" ]] && continue
  # docker-proxy 是 docker 自己的，跳过（已经在 §1 处理）
  echo "$ss_line" | grep -q docker-proxy && continue

  host_hits=$((host_hits+1))

  # 从 ss 输出抠 PID：users:(("comm",pid=12345,fd=3))
  pid=$(echo "$ss_line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
  if [[ -z "$pid" ]]; then
    echo "  ⚠️  $port 被占 但拿不到 PID（需要 sudo）：$ss_line"
    continue
  fi

  # 拿进程 comm + cmdline
  comm=$(ps -p "$pid" -o comm= 2>/dev/null || echo "?")
  args=$(ps -p "$pid" -o args= 2>/dev/null | head -c 120 || echo "?")

  echo ""
  echo "  port $port → PID=$pid"
  echo "    comm = $comm"
  echo "    cmd  = $args"

  # 判断是否在白名单（实验残留可清理）
  if echo "$comm $args" | grep -qE "$KILLABLE_PROC_REGEX"; then
    echo "    判定：⚠️  实验残留（匹配 ${KILLABLE_PROC_REGEX}），可清理"
    HOST_TO_KILL+=("$pid|$comm|$port")
  else
    echo "    判定：🛡️  非实验进程，跳过（不动）"
    HOST_TO_KEEP+=("$pid|$comm|$port")
  fi
done

if [[ $host_hits -eq 0 ]]; then
  echo "  ✅ 没有 host 进程占 mychain 端口"
fi

# 3. 列出 builder-playground 风格的残留（按 image 名字找）
echo ""
echo "3) builder-playground / op-rbuilder / reth 残留容器（不分端口）"
playground=$(docker ps -a --format "{{.Names}}\t{{.Image}}\t{{.Status}}" 2>/dev/null | \
  grep -ivE "^mychain-" | \
  grep -iE "rbuilder|playground|op-geth|reth|anvil|bproxy|builder" || true)
if [[ -n "$playground" ]]; then
  echo "$playground" | sed 's/^/  ⚠️  /'
  while IFS=$'\t' read -r name image status; do
    [[ -z "$name" ]] && continue
    # 避免重复加入
    if ! printf '%s\n' "${TO_KILL[@]}" | grep -qx "$name"; then
      TO_KILL+=("$name")
    fi
  done <<< "$playground"
else
  echo "  ✅ 没有外部 builder/reth/anvil 残留"
fi

# 4. AUTO_STOP=1 时一并清理（docker 容器 + host 进程）
echo ""
echo "============================================"

total_to_clean=$((${#TO_KILL[@]} + ${#HOST_TO_KILL[@]}))

if [[ $total_to_clean -gt 0 ]]; then
  echo "🎯 计划清理（${#TO_KILL[@]} 孤儿容器 + ${#HOST_TO_KILL[@]} host 残留进程）："
  echo ""
  if [[ ${#TO_KILL[@]} -gt 0 ]]; then
    echo "  docker 容器："
    for n in "${TO_KILL[@]}"; do echo "    - $n"; done
  fi
  if [[ ${#HOST_TO_KILL[@]} -gt 0 ]]; then
    echo "  host 进程（白名单实验残留）："
    for e in "${HOST_TO_KILL[@]}"; do
      IFS='|' read -r pid comm port <<< "$e"
      echo "    - PID=$pid comm=$comm (占 :$port)"
    done
  fi
  if [[ ${#HOST_TO_KEEP[@]} -gt 0 ]]; then
    echo ""
    echo "  🛡️  这些 host 进程不在白名单，不会动："
    for e in "${HOST_TO_KEEP[@]}"; do
      IFS='|' read -r pid comm port <<< "$e"
      echo "    - PID=$pid comm=$comm (占 :$port)"
    done
  fi
  echo ""

  if [[ $AUTO_STOP -eq 1 ]]; then
    echo "→ AUTO-STOP，执行清理 ..."

    # 容器清理
    for n in "${TO_KILL[@]}"; do
      echo "  docker stop $n && docker rm -f $n"
      docker stop "$n" >/dev/null 2>&1 || true
      docker rm -f "$n" >/dev/null 2>&1 || true
    done

    # host 进程清理（先 SIGTERM 等 3s，不退再 SIGKILL）
    for e in "${HOST_TO_KILL[@]}"; do
      IFS='|' read -r pid comm port <<< "$e"
      echo "  kill -TERM $pid ($comm, 占 :$port)"
      if [[ $NEED_SUDO -eq 1 ]] && sudo -n true 2>/dev/null; then
        sudo kill -TERM "$pid" 2>/dev/null || true
      else
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done
    sleep 3
    # 没退的 SIGKILL
    for e in "${HOST_TO_KILL[@]}"; do
      IFS='|' read -r pid comm port <<< "$e"
      if kill -0 "$pid" 2>/dev/null; then
        echo "  kill -KILL $pid (3s 后 SIGTERM 没退，强杀)"
        if [[ $NEED_SUDO -eq 1 ]] && sudo -n true 2>/dev/null; then
          sudo kill -KILL "$pid" 2>/dev/null || true
        else
          kill -KILL "$pid" 2>/dev/null || true
        fi
      fi
    done

    echo ""
    echo "✅ 清理完成。重新验证："
    echo "  make flashblocks-debug          # 看是否所有端口都空闲了"
    echo "  make dev-up-flashblocks         # 起 v6 + v7"
  else
    echo "→ DRY-RUN 模式，没动手。要清理跑："
    echo ""
    echo "  CLEANUP=1 make flashblocks-host-cleanup"
    echo ""
    echo "或者：bash dev/scripts/flashblocks-host-cleanup.sh --auto-stop"
  fi
else
  echo "✅ 没发现孤儿容器/进程，mychain 端口都干净。"
  if [[ ${#HOST_TO_KEEP[@]} -gt 0 ]]; then
    echo ""
    echo "⚠️  但是有非白名单 host 进程占着端口（见 §2），这些不能自动 kill。"
    echo "如果你确认可以杀，手动处理："
    for e in "${HOST_TO_KEEP[@]}"; do
      IFS='|' read -r pid comm port <<< "$e"
      echo "  sudo kill $pid  # $comm 占 :$port"
    done
    echo ""
    echo "或者改 ANVIL_PORT / L2_RPC_PORT 避开冲突。"
  fi
fi
echo "============================================"
