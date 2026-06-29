#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 04-generate-genesis.sh - Generate L2 genesis files (genesis.json, rollup.json)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OPBNB_DIR="$ROOT_DIR/vendor/opbnb"
OPGETH_DIR="$ROOT_DIR/vendor/op-geth"
CONTRACTS_DIR="$OPBNB_DIR/packages/contracts-bedrock"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[GENESIS]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Load environment
if [ -f "$ROOT_DIR/config/wallets.env" ]; then
    source "$ROOT_DIR/config/wallets.env"
fi

: "${L1_RPC_URL:?Set L1_RPC_URL}"

DEPLOY_CONFIG="$CONTRACTS_DIR/deploy-config/mychain.json"
DEPLOYMENT_OUTFILE="$CONTRACTS_DIR/deployments/mychain/.deploy"
STATE_DUMP_PATH="$CONTRACTS_DIR/deploy-config/state.json"
OUTPUT_DIR="$ROOT_DIR/data"

mkdir -p "$OUTPUT_DIR"

# Step 1: Generate L2 Genesis Allocs
log "=== Step 1: Generating L2 Genesis Allocs ==="

cd "$CONTRACTS_DIR"

CONTRACT_ADDRESSES_PATH="$DEPLOYMENT_OUTFILE" \
DEPLOY_CONFIG_PATH="$DEPLOY_CONFIG" \
STATE_DUMP_PATH="$STATE_DUMP_PATH" \
    forge script scripts/L2Genesis.s.sol:L2Genesis \
    --sig 'runWithStateDump()'

log "L2 genesis allocs generated at $STATE_DUMP_PATH"

# Step 2: Generate genesis.json and rollup.json
log ""
log "=== Step 2: Generating genesis.json and rollup.json ==="

cd "$OPBNB_DIR/op-node"

go run cmd/main.go genesis l2 \
    --deploy-config "$DEPLOY_CONFIG" \
    --l1-deployments "$DEPLOYMENT_OUTFILE" \
    --outfile.l2 "$OUTPUT_DIR/genesis.json" \
    --outfile.rollup "$OUTPUT_DIR/rollup.json" \
    --l1-rpc "$L1_RPC_URL" \
    --l2-allocs "$STATE_DUMP_PATH"

log "genesis.json -> $OUTPUT_DIR/genesis.json"
log "rollup.json  -> $OUTPUT_DIR/rollup.json"

# Step 3: Add volta_time to rollup.json for 500ms block time support
log ""
log "=== Step 3: Patching rollup.json ==="

if ! jq -e '.volta_time' "$OUTPUT_DIR/rollup.json" &>/dev/null; then
    jq '. + {"volta_time": 0}' "$OUTPUT_DIR/rollup.json" > "$OUTPUT_DIR/rollup.json.tmp"
    mv "$OUTPUT_DIR/rollup.json.tmp" "$OUTPUT_DIR/rollup.json"
    log "Added volta_time=0 to rollup.json"
else
    log "volta_time already present in rollup.json"
fi

# Step 4: Generate JWT secret
log ""
log "=== Step 4: Generating JWT secret ==="

JWT_FILE="$OUTPUT_DIR/jwt.txt"
if [ ! -f "$JWT_FILE" ]; then
    openssl rand -hex 32 > "$JWT_FILE"
    log "JWT secret generated at $JWT_FILE"
else
    log "JWT secret already exists at $JWT_FILE"
fi

# Step 5: Copy files to op-geth directory
log ""
log "=== Step 5: Copying genesis files ==="

cp "$OUTPUT_DIR/genesis.json" "$OPGETH_DIR/genesis.json"
cp "$JWT_FILE" "$OPGETH_DIR/jwt.txt"
log "Copied genesis.json and jwt.txt to op-geth directory"

# Step 6: Initialize op-geth
log ""
log "=== Step 6: Initializing op-geth ==="

GETH_DATADIR="$OUTPUT_DIR/geth-datadir"
mkdir -p "$GETH_DATADIR"

cd "$OPGETH_DIR"
./build/bin/geth init \
    --datadir="$GETH_DATADIR" \
    --state.scheme path \
    --db.engine pebble \
    genesis.json

log "op-geth initialized with genesis state"

log ""
log "=== Genesis Generation Complete ==="
log ""
log "Generated files:"
log "  $OUTPUT_DIR/genesis.json"
log "  $OUTPUT_DIR/rollup.json"
log "  $OUTPUT_DIR/jwt.txt"
log "  $GETH_DATADIR/ (op-geth data)"
log ""
log "Next: run 05-start-sequencer.sh"
