#!/usr/bin/env bash
# 启动 anvil L1。首次启动时把 ANVIL_GENESIS_TIMESTAMP 写成当前 epoch 并持久化进 .env，
# 之后 anvil --state 自动恢复，重启不会受这个值影响（保持 L1 hash 稳定）。
set -euo pipefail

cd "$(dirname "$0")/.."

set -a; source .env; set +a

if [[ -z "${ANVIL_GENESIS_TIMESTAMP:-}" ]]; then
  TS=$(date +%s)
  echo "==> 首次启动 L1：把 ANVIL_GENESIS_TIMESTAMP=${TS} 写回 .env"
  if grep -qE '^ANVIL_GENESIS_TIMESTAMP=' .env; then
    sed -i.bak "s/^ANVIL_GENESIS_TIMESTAMP=.*/ANVIL_GENESIS_TIMESTAMP=${TS}/" .env
  else
    echo "ANVIL_GENESIS_TIMESTAMP=${TS}" >> .env
  fi
  rm -f .env.bak
  export ANVIL_GENESIS_TIMESTAMP="$TS"
else
  echo "==> 沿用 .env 里已有的 ANVIL_GENESIS_TIMESTAMP=${ANVIL_GENESIS_TIMESTAMP}"
fi

L1_ADDRS=workdir/shared/l1-addresses.env
COMPOSE="docker compose --env-file .env"
if [[ -f "$L1_ADDRS" ]]; then
  COMPOSE="$COMPOSE --env-file $L1_ADDRS"
fi

$COMPOSE up -d anvil
bash scripts/wait-for.sh anvil 30
