#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 02-deploy-token.sh - Deploy MyToken (ERC-20 Gas Token) on BSC L1
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[TOKEN]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Load environment
if [ -f "$ROOT_DIR/config/wallets.env" ]; then
    source "$ROOT_DIR/config/wallets.env"
fi

: "${L1_RPC_URL:?Set L1_RPC_URL in your environment}"
: "${GS_ADMIN_PRIVATE_KEY:?Set GS_ADMIN_PRIVATE_KEY}"
: "${TOKEN_INITIAL_HOLDER:?Set TOKEN_INITIAL_HOLDER}"

TOKEN_SUPPLY="${TOKEN_INITIAL_SUPPLY:-2000000000000000000000000000}"

log "=== Deploying MyToken (ERC-20 Gas Token) on BSC L1 ==="
log "  L1 RPC: $L1_RPC_URL"
log "  Initial Holder: $TOKEN_INITIAL_HOLDER"
log "  Initial Supply: $TOKEN_SUPPLY wei"

cd "$ROOT_DIR/contracts"

# Install forge-std if not present
if [ ! -d "lib/forge-std" ]; then
    log "Installing forge-std..."
    forge install foundry-rs/forge-std --no-commit
fi

log "Compiling contracts..."
forge build

log "Deploying..."
DEPLOY_OUTPUT=$(forge script script/DeployToken.s.sol:DeployToken \
    --rpc-url "$L1_RPC_URL" \
    --private-key "$GS_ADMIN_PRIVATE_KEY" \
    --broadcast \
    --slow \
    -vvv 2>&1)

echo "$DEPLOY_OUTPUT"

TOKEN_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oP 'MyToken deployed at: \K0x[a-fA-F0-9]{40}' || true)

if [ -z "$TOKEN_ADDRESS" ]; then
    TOKEN_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oP 'Contract Address: \K0x[a-fA-F0-9]{40}' | head -1 || true)
fi

if [ -n "$TOKEN_ADDRESS" ]; then
    log ""
    log "=== Token Deployed Successfully ==="
    log "  Address: $TOKEN_ADDRESS"
    log ""

    ADDR_FILE="$ROOT_DIR/config/token-address.txt"
    echo "$TOKEN_ADDRESS" > "$ADDR_FILE"
    log "Token address saved to $ADDR_FILE"
    log ""
    log "Update your config with:"
    log "  export CUSTOM_GAS_TOKEN_ADDRESS=$TOKEN_ADDRESS"
    log ""

    log "Verifying CGT v2 compliance..."
    DECIMALS=$(cast call "$TOKEN_ADDRESS" "decimals()(uint8)" --rpc-url "$L1_RPC_URL" 2>/dev/null || echo "unknown")
    NAME=$(cast call "$TOKEN_ADDRESS" "name()(string)" --rpc-url "$L1_RPC_URL" 2>/dev/null || echo "unknown")
    SYMBOL=$(cast call "$TOKEN_ADDRESS" "symbol()(string)" --rpc-url "$L1_RPC_URL" 2>/dev/null || echo "unknown")

    log "  Name: $NAME"
    log "  Symbol: $SYMBOL"
    log "  Decimals: $DECIMALS"

    if [ "$DECIMALS" != "18" ] && [ "$DECIMALS" != "unknown" ]; then
        error "Token decimals must be 18 for CGT v2 compliance. Got: $DECIMALS"
    fi
    log "  CGT v2 compliance: PASSED"
else
    warn "Could not extract token address from deployment output."
    warn "Check the output above for the deployed contract address."
fi

log ""
log "Next: run 03-deploy-l1-contracts.sh"
