#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 07-start-proposer.sh - Start op-proposer (submits state roots to L1)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OPBNB_DIR="$ROOT_DIR/vendor/opbnb"
DATA_DIR="$ROOT_DIR/data"
LOGS_DIR="$ROOT_DIR/logs"
CONTRACTS_DIR="$OPBNB_DIR/packages/contracts-bedrock"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()   { echo -e "${GREEN}[PROPOSER]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

if [ -f "$ROOT_DIR/config/wallets.env" ]; then
    source "$ROOT_DIR/config/wallets.env"
fi

: "${L1_RPC_URL:?Set L1_RPC_URL}"
: "${GS_PROPOSER_PRIVATE_KEY:?Set GS_PROPOSER_PRIVATE_KEY}"

OPNODE_RPC_PORT="${OPNODE_RPC_PORT:-8547}"
OPPROPOSER_RPC_PORT="${OPPROPOSER_RPC_PORT:-8560}"
DEPLOYMENT_OUTFILE="$CONTRACTS_DIR/deployments/mychain/.deploy"

mkdir -p "$LOGS_DIR"

L2OO_ADDRESS=$(jq -r .L2OutputOracleProxy "$DEPLOYMENT_OUTFILE" 2>/dev/null || echo "")
if [ -z "$L2OO_ADDRESS" ] || [ "$L2OO_ADDRESS" = "null" ]; then
    if [ -f "$ROOT_DIR/deployments/l1-deploy.json" ]; then
        L2OO_ADDRESS=$(jq -r .L2OutputOracleProxy "$ROOT_DIR/deployments/l1-deploy.json" 2>/dev/null || echo "")
    fi
fi

[ -n "$L2OO_ADDRESS" ] && [ "$L2OO_ADDRESS" != "null" ] || \
    error "Cannot find L2OutputOracleProxy address. Deploy L1 contracts first."

log "=== Starting op-proposer ==="
log "  L1 RPC: $L1_RPC_URL"
log "  Rollup RPC: http://localhost:$OPNODE_RPC_PORT"
log "  L2OutputOracle: $L2OO_ADDRESS"

"$OPBNB_DIR/op-proposer/bin/op-proposer" \
    --poll-interval=1s \
    --rpc.port="$OPPROPOSER_RPC_PORT" \
    --rollup-rpc=http://localhost:${OPNODE_RPC_PORT} \
    --l2oo-address="$L2OO_ADDRESS" \
    --private-key="$GS_PROPOSER_PRIVATE_KEY" \
    --l1-eth-rpc="$L1_RPC_URL" \
    > "$LOGS_DIR/op-proposer.log" 2>&1 &

PROPOSER_PID=$!
echo "$PROPOSER_PID" > "$DATA_DIR/op-proposer.pid"
log "op-proposer started (PID: $PROPOSER_PID)"
log "  RPC: http://localhost:$OPPROPOSER_RPC_PORT"
log "  Logs: $LOGS_DIR/op-proposer.log"
log ""
log "Monitor: tail -f $LOGS_DIR/op-proposer.log"
