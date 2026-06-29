#!/usr/bin/env bash
# 用 patched genesis.json 初始化 op-geth datadir，捕获真实的 L2 genesis hash，
# 然后 patch rollup.json 的 genesis.l2.hash 字段，让 op-node 能与 op-geth 对齐。
set -euo pipefail

cd "$(dirname "$0")/.."

set -a; source .env; set +a

if [[ ! -s workdir/shared/genesis.json ]]; then
  echo "❌ workdir/shared/genesis.json 不存在或为空，先 make deploy-genesis" >&2
  exit 1
fi
if [[ ! -s workdir/shared/rollup.json ]]; then
  echo "❌ workdir/shared/rollup.json 不存在或为空，先 make deploy-genesis" >&2
  exit 1
fi

OLD_HASH=$(jq -r '.genesis.l2.hash' workdir/shared/rollup.json)
echo "==> rollup.json 里旧的 L2 genesis hash = $OLD_HASH"

echo "==> 用 patched genesis.json 跑 op-geth init..."
docker compose --env-file .env --profile deploy run --rm op-geth-init

# geth init 日志里的 hash 是被截断的短格式（22b01e..d2b52f），grep 拿不到完整值，
# 必须临时启动 op-geth 然后通过 RPC 读 block 0 的完整 hash。
echo ""
echo "==> 临时启动 op-geth 读 block 0 真实 hash..."
docker compose --env-file .env up -d op-geth >/dev/null

NEW_HASH=""
for i in {1..30}; do
  sleep 1
  NEW_HASH=$(curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' \
    "http://localhost:${L2_RPC_PORT}" 2>/dev/null | jq -r '.result.hash // empty' 2>/dev/null || true)
  if [[ -n "$NEW_HASH" && "$NEW_HASH" == 0x* ]]; then
    break
  fi
  echo -n "."
done
echo ""

docker compose --env-file .env stop op-geth >/dev/null

if [[ -z "$NEW_HASH" || "$NEW_HASH" != 0x* ]]; then
  echo "❌ 拿不到新 genesis hash（30s 超时），op-geth 可能启动失败" >&2
  echo "    检查 docker logs mychain-op-geth" >&2
  exit 1
fi

echo "==> 新 L2 genesis hash = $NEW_HASH"

if [[ "$OLD_HASH" == "$NEW_HASH" ]]; then
  echo "✅ hash 没变，rollup.json 不需要 patch（说明 alloc 注入没生效或被 EVM 自动包含）"
else
  echo "==> patch rollup.json: $OLD_HASH -> $NEW_HASH"
  TMP=$(mktemp)
  jq --arg h "$NEW_HASH" '.genesis.l2.hash = $h' workdir/shared/rollup.json > "$TMP"
  mv "$TMP" workdir/shared/rollup.json
fi

chmod 644 workdir/shared/*.json
echo "✅ op-geth datadir 已初始化，rollup.json 已对齐"
