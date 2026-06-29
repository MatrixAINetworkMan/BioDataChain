#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 01-generate-wallets.sh - Generate 4 key accounts for chain operation
#   Admin, Batcher, Proposer, Sequencer
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[WALLETS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

WALLET_FILE="$ROOT_DIR/config/wallets.env"

if [ -f "$WALLET_FILE" ]; then
    warn "Wallet file already exists at $WALLET_FILE"
    warn "To regenerate, delete it first."
    exit 0
fi

generate_wallet() {
    local label="$1"
    local privkey
    privkey="0x$(openssl rand -hex 32)"
    echo "$privkey"
}

compute_address_from_key() {
    local privkey="$1"
    if command -v cast &>/dev/null; then
        cast wallet address "$privkey" 2>/dev/null
    else
        echo "INSTALL_FOUNDRY_TO_COMPUTE"
    fi
}

log "Generating 4 wallets for chain operation..."
log ""

ADMIN_KEY=$(generate_wallet "Admin")
BATCHER_KEY=$(generate_wallet "Batcher")
PROPOSER_KEY=$(generate_wallet "Proposer")
SEQUENCER_KEY=$(generate_wallet "Sequencer")

ADMIN_ADDR=$(compute_address_from_key "$ADMIN_KEY")
BATCHER_ADDR=$(compute_address_from_key "$BATCHER_KEY")
PROPOSER_ADDR=$(compute_address_from_key "$PROPOSER_KEY")
SEQUENCER_ADDR=$(compute_address_from_key "$SEQUENCER_KEY")

cat > "$WALLET_FILE" <<EOF
# =============================================================================
# MyChain Wallet Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# WARNING: Keep this file secure! Never commit to version control.
#          In production, use hardware wallets or multisig for Admin.
# =============================================================================

# Admin account - owns upgradeable contracts (use multisig in production!)
export GS_ADMIN_ADDRESS=$ADMIN_ADDR
export GS_ADMIN_PRIVATE_KEY=$ADMIN_KEY

# Batcher account - submits transaction batches to L1
# Fund with ~15 BNB (testnet) or ~2 BNB/month (mainnet)
export GS_BATCHER_ADDRESS=$BATCHER_ADDR
export GS_BATCHER_PRIVATE_KEY=$BATCHER_KEY

# Proposer account - submits L2 state roots to L1
# Fund with ~2 BNB (testnet)
export GS_PROPOSER_ADDRESS=$PROPOSER_ADDR
export GS_PROPOSER_PRIVATE_KEY=$PROPOSER_KEY

# Sequencer account - signs L2 blocks (no funding needed)
export GS_SEQUENCER_ADDRESS=$SEQUENCER_ADDR
export GS_SEQUENCER_PRIVATE_KEY=$SEQUENCER_KEY

# Token holder for initial supply
export TOKEN_INITIAL_HOLDER=$ADMIN_ADDR
EOF

chmod 600 "$WALLET_FILE"

log "Wallets generated and saved to: $WALLET_FILE"
log ""
log "Account Summary:"
log "  Admin:     $ADMIN_ADDR"
log "  Batcher:   $BATCHER_ADDR"
log "  Proposer:  $PROPOSER_ADDR"
log "  Sequencer: $SEQUENCER_ADDR"
log ""
log "IMPORTANT: Fund the following accounts on BSC before deploying:"
log "  Admin     - 1 BNB"
log "  Batcher   - 15 BNB (testnet) / 2 BNB (mainnet initial)"
log "  Proposer  - 2 BNB"
log ""
log "Next: source the wallets file and run 02-deploy-token.sh"
log "  source $WALLET_FILE"
