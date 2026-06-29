#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 06-start-batcher.sh - Start op-batcher (publishes tx batches to L1)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OPBNB_DIR="$ROOT_DIR/vendor/opbnb"
DATA_DIR="$ROOT_DIR/data"
LOGS_DIR="$ROOT_DIR/logs"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()   { echo -e "${GREEN}[BATCHER]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

if [ -f "$ROOT_DIR/config/wallets.env" ]; then
    source "$ROOT_DIR/config/wallets.env"
fi

: "${L1_RPC_URL:?Set L1_RPC_URL}"
: "${GS_BATCHER_PRIVATE_KEY:?Set GS_BATCHER_PRIVATE_KEY}"

OPGETH_HTTP_PORT="${OPGETH_HTTP_PORT:-8545}"
OPNODE_RPC_PORT="${OPNODE_RPC_PORT:-8547}"
OPBATCHER_RPC_PORT="${OPBATCHER_RPC_PORT:-8548}"

mkdir -p "$LOGS_DIR"

log "=== Starting op-batcher ==="
log "  L1 RPC: $L1_RPC_URL"
log "  L2 RPC: http://localhost:$OPGETH_HTTP_PORT"
log "  Rollup RPC: http://localhost:$OPNODE_RPC_PORT"

"$OPBNB_DIR/op-batcher/bin/op-batcher" \
    --l2-eth-rpc=http://localhost:${OPGETH_HTTP_PORT} \
    --rollup-rpc=http://localhost:${OPNODE_RPC_PORT} \
    --poll-interval=5s \
    --sub-safety-margin=30 \
    --num-confirmations=4 \
    --safe-abort-nonce-too-low-count=3 \
    --resubmission-timeout=30s \
    --rpc.addr=0.0.0.0 \
    --rpc.port="$OPBATCHER_RPC_PORT" \
    --batch-type=1 \
    --data-availability-type=auto \
    --target-num-frames=2 \
    --rpc.enable-admin \
    --max-channel-duration=20 \
    --l1-eth-rpc="$L1_RPC_URL" \
    --private-key="$GS_BATCHER_PRIVATE_KEY" \
    > "$LOGS_DIR/op-batcher.log" 2>&1 &

BATCHER_PID=$!
echo "$BATCHER_PID" > "$DATA_DIR/op-batcher.pid"
log "op-batcher started (PID: $BATCHER_PID)"
log "  RPC: http://localhost:$OPBATCHER_RPC_PORT"
log "  Logs: $LOGS_DIR/op-batcher.log"
log ""
log "Monitor: tail -f $LOGS_DIR/op-batcher.log"
