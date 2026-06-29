#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 08-start-bridge-node.sh - Start a bridge/RPC node (non-sequencer fullnode)
#   Requires genesis.json, rollup.json, jwt.txt from the sequencer setup
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OPBNB_DIR="$ROOT_DIR/vendor/opbnb"
OPGETH_DIR="$ROOT_DIR/vendor/op-geth"
DATA_DIR="$ROOT_DIR/data"
LOGS_DIR="$ROOT_DIR/logs"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()   { echo -e "${GREEN}[BRIDGE]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

if [ -f "$ROOT_DIR/config/wallets.env" ]; then
    source "$ROOT_DIR/config/wallets.env"
fi

: "${L1_RPC_URL:?Set L1_RPC_URL}"
: "${L2_CHAIN_ID:=42170}"

JWT_FILE="$DATA_DIR/jwt.txt"
ROLLUP_CONFIG="$DATA_DIR/rollup.json"
GENESIS_FILE="$DATA_DIR/genesis.json"

[ -f "$JWT_FILE" ] || error "jwt.txt not found"
[ -f "$ROLLUP_CONFIG" ] || error "rollup.json not found"
[ -f "$GENESIS_FILE" ] || error "genesis.json not found"

BRIDGE_GETH_DATADIR="$DATA_DIR/bridge-geth-datadir"
BRIDGE_HTTP_PORT=9545
BRIDGE_WS_PORT=9546
BRIDGE_AUTH_PORT=9551
BRIDGE_METRICS_PORT=6061
BRIDGE_NODE_RPC_PORT=9547
BRIDGE_NODE_METRICS_PORT=7071

mkdir -p "$LOGS_DIR"

# Initialize op-geth for bridge node if needed
if [ ! -d "$BRIDGE_GETH_DATADIR/geth" ]; then
    log "Initializing bridge op-geth..."
    mkdir -p "$BRIDGE_GETH_DATADIR"
    "$OPGETH_DIR/build/bin/geth" init \
        --datadir="$BRIDGE_GETH_DATADIR" \
        --state.scheme path \
        --db.engine pebble \
        "$GENESIS_FILE"
fi

log "=== Starting Bridge op-geth ==="

"$OPGETH_DIR/build/bin/geth" \
    --datadir "$BRIDGE_GETH_DATADIR" \
    --http \
    --http.corsdomain="*" \
    --http.vhosts="*" \
    --http.addr=0.0.0.0 \
    --http.port="$BRIDGE_HTTP_PORT" \
    --http.api=web3,debug,eth,txpool,net,engine \
    --ws \
    --ws.addr=0.0.0.0 \
    --ws.port="$BRIDGE_WS_PORT" \
    --ws.origins="*" \
    --ws.api=debug,eth,txpool,net,engine \
    --syncmode=full \
    --gcmode=full \
    --nodiscover \
    --maxpeers=10 \
    --networkid="$L2_CHAIN_ID" \
    --authrpc.vhosts="*" \
    --authrpc.addr=0.0.0.0 \
    --authrpc.port="$BRIDGE_AUTH_PORT" \
    --authrpc.jwtsecret="$JWT_FILE" \
    --txpool.globalslots=10000 \
    --txpool.globalqueue=5000 \
    --txpool.accountqueue=500 \
    --txpool.accountslots=500 \
    --txpool.reannouncetime=3m \
    --txpool.reannounceremotes=true \
    --txpool.pricelimit=1 \
    --txpool.nolocals=true \
    --cache=10000 \
    --cache.preimages \
    --rollup.disabletxpoolgossip=false \
    --history.transactions=0 \
    --metrics \
    --metrics.port="$BRIDGE_METRICS_PORT" \
    --metrics.addr=0.0.0.0 \
    --verbosity=3 \
    > "$LOGS_DIR/bridge-op-geth.log" 2>&1 &

BGETH_PID=$!
echo "$BGETH_PID" > "$DATA_DIR/bridge-op-geth.pid"
log "Bridge op-geth started (PID: $BGETH_PID)"

sleep 5

log "=== Starting Bridge op-node ==="

"$OPBNB_DIR/op-node/bin/op-node" \
    --l1.trustrpc \
    --l2=http://localhost:${BRIDGE_AUTH_PORT} \
    --l2.jwt-secret="$JWT_FILE" \
    --verifier.l1-confs=15 \
    --l1.http-poll-interval=3s \
    --l1.epoch-poll-interval=3s \
    --l1.rpc-max-batch-size=20 \
    --rollup.config="$ROLLUP_CONFIG" \
    --rpc.addr=0.0.0.0 \
    --rpc.port="$BRIDGE_NODE_RPC_PORT" \
    --rpc.enable-admin \
    --l1.max-concurrency=20 \
    --l1="$L1_RPC_URL" \
    --metrics.enabled \
    --metrics.port="$BRIDGE_NODE_METRICS_PORT" \
    --metrics.addr=0.0.0.0 \
    > "$LOGS_DIR/bridge-op-node.log" 2>&1 &

BNODE_PID=$!
echo "$BNODE_PID" > "$DATA_DIR/bridge-op-node.pid"
log "Bridge op-node started (PID: $BNODE_PID)"

log ""
log "=== Bridge Node Started ==="
log "  RPC: http://localhost:$BRIDGE_HTTP_PORT"
log "  Monitor: tail -f $LOGS_DIR/bridge-op-geth.log $LOGS_DIR/bridge-op-node.log"
