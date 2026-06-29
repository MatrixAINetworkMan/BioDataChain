#!/usr/bin/env bash
# 启动 L1 geth，等 RPC 就绪
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; source .env; set +a

if [[ -z "${VALIDATOR_ADDRESS:-}" ]]; then
  echo "❌ VALIDATOR_ADDRESS 为空。请先执行：make init" >&2
  exit 1
fi

if [[ ! -f secrets/password.txt ]]; then
  echo "❌ secrets/password.txt 不存在。请先执行：make init" >&2
  exit 1
fi

if [[ -z "$(ls keystore/UTC--* 2>/dev/null || true)" ]]; then
  echo "❌ keystore 为空。请先执行：make init" >&2
  exit 1
fi

docker compose --env-file .env up -d geth-l1

echo ""
echo "==> 等待 L1 RPC 就绪 + 已经出第一个块..."
# 用 127.0.0.1 不要 localhost（见 03-status.sh 同名注释）
RPC="http://127.0.0.1:${HTTP_PORT:-8545}"

# 不只等 RPC 接受连接，还等 block number 真的能查出来 + > 0；
# 否则后续脚本里第一次 RPC 调用会撞 geth 启动早期的 race condition。
#
# 注意：分两步赋值 + || true，避免 curl 瞬时失败（exit 7/52/56）经 pipefail
# 升级成整脚本退出。geth 启动早期前几秒 RPC server 会有几次 reset 完全正常。
for i in {1..60}; do
  RESP="$(curl -sf -m 5 -X POST "$RPC" \
      -H 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
      2>/dev/null || true)"
  BLOCK_HEX="$(printf '%s' "$RESP" | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("result",""))
except Exception:
    pass' 2>/dev/null || true)"
  if [[ -n "$BLOCK_HEX" && "$BLOCK_HEX" != "0x0" ]]; then
    echo "✅ L1 RPC 就绪 → $RPC (耗时 ~${i}s, block=$BLOCK_HEX)"
    echo ""
    break
  fi
  sleep 1
  if [[ $i -eq 60 ]]; then
    echo "❌ 等 60s 仍没出块。查日志：make logs" >&2
    exit 1
  fi
done

bash scripts/03-status.sh
