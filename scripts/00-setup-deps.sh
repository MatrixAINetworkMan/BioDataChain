#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 00-setup-deps.sh - Install and verify all required dependencies
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[SETUP]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

check_cmd() {
    if command -v "$1" &>/dev/null; then
        log "  $1: $(command -v "$1")"
        return 0
    else
        warn "  $1: NOT FOUND"
        return 1
    fi
}

log "=== Checking system dependencies ==="

MISSING=0

for cmd in git go node pnpm jq direnv make openssl curl; do
    check_cmd "$cmd" || MISSING=$((MISSING + 1))
done

check_cmd forge || {
    warn "Foundry not installed. Install with: curl -L https://foundry.paradigm.xyz | bash && foundryup"
    MISSING=$((MISSING + 1))
}

if [ "$MISSING" -gt 0 ]; then
    warn "$MISSING dependencies missing. Install them before proceeding."
else
    log "All dependencies satisfied."
fi

log ""
log "=== Version summary ==="
go version 2>/dev/null || true
node --version 2>/dev/null || true
forge --version 2>/dev/null || true

log ""
log "=== Cloning opBNB and op-geth repositories ==="

OPBNB_DIR="$ROOT_DIR/vendor/opbnb"
OPGETH_DIR="$ROOT_DIR/vendor/op-geth"

if [ ! -d "$OPBNB_DIR" ]; then
    log "Cloning opBNB..."
    mkdir -p "$ROOT_DIR/vendor"
    git clone https://github.com/bnb-chain/opbnb.git "$OPBNB_DIR"
    cd "$OPBNB_DIR"
    git checkout develop
else
    log "opBNB already cloned at $OPBNB_DIR"
fi

if [ ! -d "$OPGETH_DIR" ]; then
    log "Cloning op-geth..."
    git clone https://github.com/bnb-chain/op-geth.git "$OPGETH_DIR"
    cd "$OPGETH_DIR"
    git checkout develop
else
    log "op-geth already cloned at $OPGETH_DIR"
fi

log ""
log "=== Building opBNB components ==="
cd "$OPBNB_DIR"
pnpm install
make op-node op-batcher op-proposer
log "opBNB components built successfully."

log ""
log "=== Building op-geth ==="
cd "$OPGETH_DIR"
make geth
log "op-geth built successfully."

log ""
log "Setup complete. Next: run 01-generate-wallets.sh"
