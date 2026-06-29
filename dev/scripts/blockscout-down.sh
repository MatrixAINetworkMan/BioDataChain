#!/usr/bin/env bash
# 拆 Blockscout（仅自己 6 个容器，不动主链）
#
# 用法：
#   bash scripts/blockscout-down.sh           # stop + rm 容器，保留 DB volume
#   bash scripts/blockscout-down.sh --clean   # 同时删 volume（DB 数据归零，下次重新索引）
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f blockscout/docker-compose.yml ]]; then
  echo "❌ blockscout/docker-compose.yml 不存在" >&2
  exit 1
fi

CLEAN=0
# -t 5 把 stop timeout 从 compose 文件里的 stop_grace_period 强行压到 5s。
# Erlang BEAM 经常吃 SIGTERM 不退出，没有这个超时控制就会死等 → 看起来"不动了"。
# clean 模式反正卷都要删，更没必要让 backend 优雅落盘，5s → 直接 SIGKILL。
CMD=(docker compose -f blockscout/docker-compose.yml --env-file .env down -t 5)
if [[ "${1:-}" == "--clean" ]]; then
  CMD+=(-v --remove-orphans)
  CLEAN=1
  echo "==> 拆 Blockscout 并删除 DB / Redis 数据 ..."
else
  echo "==> 拆 Blockscout（保留 DB 数据，下次 up 不用重新索引）..."
fi

# 兜底：如果 backend 容器明显卡在 Stopping 状态，开个 watchdog 在 8s 后强杀，
# 防止"Erlang 不响应 SIGTERM + docker 内部循环 bug"导致整个 down 命令永远不返回。
if docker ps --format '{{.Names}}' | grep -q '^mychain-blockscout-backend$'; then
  (
    sleep 8
    if docker ps --format '{{.Names}}' | grep -q '^mychain-blockscout-backend$'; then
      echo "    ⚠️  backend 8s 内没退出，强杀（Erlang 偶尔不响应 SIGTERM）"
      docker kill mychain-blockscout-backend >/dev/null 2>&1 || true
    fi
  ) &
  WATCHDOG=$!
fi

"${CMD[@]}"

# down 已返回；watchdog 还活着就让它自己结束（kill 一下省 ps 输出）
if [[ -n "${WATCHDOG:-}" ]]; then
  kill "$WATCHDOG" >/dev/null 2>&1 || true
  wait "$WATCHDOG" 2>/dev/null || true
fi

# clean 模式必须把链指纹一起删掉，下次 up 才会按"全新链"处理而不是误以为还是同一条
if [[ "$CLEAN" == "1" ]]; then
  rm -f blockscout/.chain-fingerprint
fi

echo ""
echo "✅ 已拆掉 Blockscout"
echo "   主链（anvil / op-geth / op-node / op-batcher）不受影响"
