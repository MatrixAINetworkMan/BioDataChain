#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 09-check-status.sh - Check the health and sync status of all components
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$ROOT_DIR/data"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[STATUS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[DOWN]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

OPGETH_HTTP_PORT="${OPGETH_HTTP_PORT:-8545}"
OPNODE_RPC_PORT="${OPNODE_RPC_PORT:-8547}"
OPNODE_METRICS_PORT="${OPNODE_METRICS_PORT:-7070}"

echo ""
echo "============================================="
echo "  MyChain L2 - System Status Check"
echo "============================================="
echo ""

# Check process status
echo "--- Process Status ---"
for svc in op-geth op-node op-batcher op-proposer bridge-op-geth bridge-op-node; do
    PID_FILE="$DATA_DIR/${svc}.pid"
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            log "$svc: RUNNING (PID $PID)"
        else
            fail "$svc: STOPPED (stale PID $PID)"
        fi
    else
        info "$svc: not configured"
    fi
done

echo ""
echo "--- L2 Chain Status ---"

# Check op-geth
BLOCK_NUM=$(curl -s -X POST http://localhost:${OPGETH_HTTP_PORT} \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    2>/dev/null | jq -r '.result // empty' 2>/dev/null || echo "")

if [ -n "$BLOCK_NUM" ]; then
    BLOCK_DEC=$(printf "%d" "$BLOCK_NUM" 2>/dev/null || echo "$BLOCK_NUM")
    log "op-geth block height: $BLOCK_DEC ($BLOCK_NUM)"
else
    fail "op-geth: not responding on port $OPGETH_HTTP_PORT"
fi

# Check op-node sync status
SYNC_STATUS=$(curl -s -X POST http://localhost:${OPNODE_RPC_PORT} \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
    2>/dev/null | jq '.result' 2>/dev/null || echo "")

if [ -n "$SYNC_STATUS" ] && [ "$SYNC_STATUS" != "" ] && [ "$SYNC_STATUS" != "null" ]; then
    UNSAFE=$(echo "$SYNC_STATUS" | jq -r '.unsafe_l2.number // "N/A"')
    SAFE=$(echo "$SYNC_STATUS" | jq -r '.safe_l2.number // "N/A"')
    FINALIZED=$(echo "$SYNC_STATUS" | jq -r '.finalized_l2.number // "N/A"')
    L1_HEAD=$(echo "$SYNC_STATUS" | jq -r '.head_l1.number // "N/A"')

    log "L2 Unsafe Head:    $UNSAFE"
    log "L2 Safe Head:      $SAFE"
    log "L2 Finalized:      $FINALIZED"
    log "L1 Head:           $L1_HEAD"

    if [ "$UNSAFE" != "N/A" ] && [ "$SAFE" != "N/A" ]; then
        LAG=$((UNSAFE - SAFE))
        if [ "$LAG" -gt 100 ]; then
            warn "Safe head is lagging by $LAG blocks (batcher may need attention)"
        else
            log "Safe-Unsafe lag: $LAG blocks (healthy)"
        fi
    fi
else
    fail "op-node: not responding on port $OPNODE_RPC_PORT"
fi

# Check metrics
echo ""
echo "--- Metrics Endpoints ---"
for endpoint in "op-geth:${OPGETH_METRICS_PORT:-6060}" "op-node:${OPNODE_METRICS_PORT}"; do
    NAME=$(echo "$endpoint" | cut -d: -f1)
    PORT=$(echo "$endpoint" | cut -d: -f2)
    if curl -s "http://localhost:$PORT/debug/metrics" >/dev/null 2>&1; then
        log "$NAME metrics: http://localhost:$PORT/debug/metrics"
    else
        info "$NAME metrics: not available on port $PORT"
    fi
done

echo ""
echo "--- Chain Info ---"
CHAIN_ID=$(curl -s -X POST http://localhost:${OPGETH_HTTP_PORT} \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    2>/dev/null | jq -r '.result // empty' 2>/dev/null || echo "")

if [ -n "$CHAIN_ID" ]; then
    CHAIN_DEC=$(printf "%d" "$CHAIN_ID" 2>/dev/null || echo "$CHAIN_ID")
    log "Chain ID: $CHAIN_DEC ($CHAIN_ID)"
fi

echo ""
echo "============================================="
