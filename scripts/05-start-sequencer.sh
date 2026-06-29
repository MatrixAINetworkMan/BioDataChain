#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 05-start-sequencer.sh - Start op-geth (execution) + op-node (consensus)
#                         in Sequencer mode
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OPBNB_DIR="$ROOT_DIR/vendor/opbnb"
OPGETH_DIR="$ROOT_DIR/vendor/op-geth"
DATA_DIR="$ROOT_DIR/data"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[SEQ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Load environment
if [ -f "$ROOT_DIR/config/wallets.env" ]; then
    source "$ROOT_DIR/config/wallets.env"
fi

: "${L1_RPC_URL:?Set L1_RPC_URL}"
: "${L2_CHAIN_ID:=42170}"
: "${GS_SEQUENCER_ADDRESS:?Set GS_SEQUENCER_ADDRESS}"
: "${GS_SEQUENCER_PRIVATE_KEY:?Set GS_SEQUENCER_PRIVATE_KEY}"

GETH_DATADIR="$DATA_DIR/geth-datadir"
JWT_FILE="$DATA_DIR/jwt.txt"
ROLLUP_CONFIG="$DATA_DIR/rollup.json"
LOGS_DIR="$ROOT_DIR/logs"

mkdir -p "$LOGS_DIR"

[ -d "$GETH_DATADIR" ] || error "op-geth datadir not found. Run 04-generate-genesis.sh first."
[ -f "$JWT_FILE" ] || error "jwt.txt not found. Run 04-generate-genesis.sh first."
[ -f "$ROLLUP_CONFIG" ] || error "rollup.json not found. Run 04-generate-genesis.sh first."

L1_RPC_KIND="${L1_RPC_KIND:-standard}"
OPGETH_HTTP_PORT="${OPGETH_HTTP_PORT:-8545}"
OPGETH_WS_PORT="${OPGETH_WS_PORT:-8546}"
OPGETH_AUTH_PORT="${OPGETH_AUTH_PORT:-8551}"
OPGETH_METRICS_PORT="${OPGETH_METRICS_PORT:-6060}"
OPNODE_RPC_PORT="${OPNODE_RPC_PORT:-8547}"
OPNODE_METRICS_PORT="${OPNODE_METRICS_PORT:-7070}"

# --- Start op-geth ---
log "=== Starting op-geth (Sequencer / Execution Client) ==="

"$OPGETH_DIR/build/bin/geth" \
    --datadir "$GETH_DATADIR" \
    --http \
    --http.corsdomain="*" \
    --http.vhosts="*" \
    --http.addr=0.0.0.0 \
    --http.port="$OPGETH_HTTP_PORT" \
    --http.api=web3,debug,eth,txpool,net,engine \
    --ws \
    --ws.addr=0.0.0.0 \
    --ws.port="$OPGETH_WS_PORT" \
    --ws.origins="*" \
    --ws.api=debug,eth,txpool,net,engine \
    --syncmode=full \
    --gcmode=archive \
    --mine \
    --miner.newpayload-timeout=650ms \
    --miner.gaslimit=150000000 \
    --miner.gasprice=1 \
    --miner.etherbase="$GS_SEQUENCER_ADDRESS" \
    --nodiscover \
    --maxpeers=10 \
    --networkid="$L2_CHAIN_ID" \
    --authrpc.vhosts='*' \
    --authrpc.addr=0.0.0.0 \
    --authrpc.port="$OPGETH_AUTH_PORT" \
    --authrpc.jwtsecret="$JWT_FILE" \
    --txpool.globalslots=20000 \
    --txpool.globalqueue=10000 \
    --txpool.accountqueue=500 \
    --txpool.accountslots=500 \
    --txpool.pricelimit=1 \
    --txpool.nolocals=true \
    --txpool.reannouncetime=3m \
    --txpool.reannounceremotes=true \
    --cache=20000 \
    --cache.preimages \
    --rollup.disabletxpoolgossip=false \
    --pathdb.nodebuffer=list \
    --pathdb.proposeblock=3600 \
    --pathdb.enableproofkeeper \
    --metrics \
    --metrics.port="$OPGETH_METRICS_PORT" \
    --metrics.addr=0.0.0.0 \
    --verbosity=3 \
    > "$LOGS_DIR/op-geth.log" 2>&1 &

GETH_PID=$!
echo "$GETH_PID" > "$DATA_DIR/op-geth.pid"
log "op-geth started (PID: $GETH_PID)"
log "  HTTP: http://localhost:$OPGETH_HTTP_PORT"
log "  WS:   ws://localhost:$OPGETH_WS_PORT"
log "  Auth: http://localhost:$OPGETH_AUTH_PORT"
log "  Logs: $LOGS_DIR/op-geth.log"

# Wait for op-geth to initialize
log "Waiting for op-geth to start..."
sleep 5

# --- Start op-node ---
log ""
log "=== Starting op-node (Sequencer / Consensus Client) ==="

"$OPBNB_DIR/op-node/bin/op-node" \
    --l1.trustrpc \
    --l2=http://localhost:${OPGETH_AUTH_PORT} \
    --l2.jwt-secret="$JWT_FILE" \
    --sequencer.enabled=true \
    --sequencer.l1-confs=15 \
    --sequencer.combined-engine \
    --verifier.l1-confs=15 \
    --l1.http-poll-interval=3s \
    --l1.epoch-poll-interval=3s \
    --l1.rpc-max-batch-size=20 \
    --rollup.config="$ROLLUP_CONFIG" \
    --rpc.addr=0.0.0.0 \
    --rpc.port="$OPNODE_RPC_PORT" \
    --rpc.enable-admin \
    --sequencer.priority \
    --l1.max-concurrency=20 \
    --p2p.sequencer.key="$GS_SEQUENCER_PRIVATE_KEY" \
    --l1="$L1_RPC_URL" \
    --l1.rpckind="$L1_RPC_KIND" \
    --metrics.enabled \
    --metrics.port="$OPNODE_METRICS_PORT" \
    --metrics.addr=0.0.0.0 \
    > "$LOGS_DIR/op-node.log" 2>&1 &

NODE_PID=$!
echo "$NODE_PID" > "$DATA_DIR/op-node.pid"
log "op-node started (PID: $NODE_PID)"
log "  RPC:  http://localhost:$OPNODE_RPC_PORT"
log "  Logs: $LOGS_DIR/op-node.log"

log ""
log "=== Sequencer Started ==="
log "Monitor: tail -f $LOGS_DIR/op-geth.log $LOGS_DIR/op-node.log"
log ""
log "IMPORTANT: Start op-batcher and op-proposer within 3600 seconds!"
log "Next: run 06-start-batcher.sh and 07-start-proposer.sh"
