#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 03-deploy-l1-contracts.sh - Deploy OP Stack L1 contracts on BSC
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OPBNB_DIR="$ROOT_DIR/vendor/opbnb"
CONTRACTS_DIR="$OPBNB_DIR/packages/contracts-bedrock"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[L1-DEPLOY]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Load environment
if [ -f "$ROOT_DIR/config/wallets.env" ]; then
    source "$ROOT_DIR/config/wallets.env"
fi

: "${L1_RPC_URL:?Set L1_RPC_URL}"
: "${GS_ADMIN_PRIVATE_KEY:?Set GS_ADMIN_PRIVATE_KEY}"
: "${GS_ADMIN_ADDRESS:?Set GS_ADMIN_ADDRESS}"
: "${GS_BATCHER_ADDRESS:?Set GS_BATCHER_ADDRESS}"
: "${GS_PROPOSER_ADDRESS:?Set GS_PROPOSER_ADDRESS}"
: "${GS_SEQUENCER_ADDRESS:?Set GS_SEQUENCER_ADDRESS}"

CUSTOM_GAS_TOKEN_ADDRESS="${CUSTOM_GAS_TOKEN_ADDRESS:-}"
L2_CHAIN_ID="${L2_CHAIN_ID:-42170}"

if [ -z "$CUSTOM_GAS_TOKEN_ADDRESS" ]; then
    if [ -f "$ROOT_DIR/config/token-address.txt" ]; then
        CUSTOM_GAS_TOKEN_ADDRESS=$(cat "$ROOT_DIR/config/token-address.txt")
        log "Loaded token address from config: $CUSTOM_GAS_TOKEN_ADDRESS"
    else
        error "CUSTOM_GAS_TOKEN_ADDRESS not set. Deploy the token first with 02-deploy-token.sh"
    fi
fi

log "=== Deploying L1 Contracts on BSC ==="
log "  L1 RPC: $L1_RPC_URL"
log "  L2 Chain ID: $L2_CHAIN_ID"
log "  Gas Token: $CUSTOM_GAS_TOKEN_ADDRESS"
log "  Admin: $GS_ADMIN_ADDRESS"
log "  Batcher: $GS_BATCHER_ADDRESS"
log "  Proposer: $GS_PROPOSER_ADDRESS"
log "  Sequencer: $GS_SEQUENCER_ADDRESS"

# Check Create2 factory
log ""
log "Checking Create2 factory..."
FACTORY_SIZE=$(cast codesize 0x4e59b44847b379578588920cA78FbF26c0B4956C --rpc-url "$L1_RPC_URL" 2>/dev/null || echo "0")

if [ "$FACTORY_SIZE" = "0" ]; then
    log "Create2 factory not found. Deploying..."
    log "Funding factory deployer 0x3fAB184622Dc19b6109349B94811493BF2a45362..."

    cast send 0x3fAB184622Dc19b6109349B94811493BF2a45362 \
        --value 1ether \
        --rpc-url "$L1_RPC_URL" \
        --private-key "$GS_ADMIN_PRIVATE_KEY"

    log "Publishing factory deployment tx..."
    cast publish --rpc-url "$L1_RPC_URL" \
        0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222

    sleep 10
    FACTORY_SIZE=$(cast codesize 0x4e59b44847b379578588920cA78FbF26c0B4956C --rpc-url "$L1_RPC_URL" 2>/dev/null || echo "0")
    if [ "$FACTORY_SIZE" = "0" ]; then
        error "Create2 factory deployment failed."
    fi
    log "Create2 factory deployed successfully."
else
    log "Create2 factory already deployed (code size: $FACTORY_SIZE)."
fi

# Fetch L1 block parameters
log ""
log "Fetching L1 block parameters..."

L1_BLOCK_INFO=$(cast block latest --rpc-url "$L1_RPC_URL" --json 2>/dev/null)
L1_BLOCK_TAG=$(echo "$L1_BLOCK_INFO" | jq -r '.number')
L1_BLOCK_TAG_HEX=$(printf "0x%x" "$L1_BLOCK_TAG")
L1_TIMESTAMP=$(echo "$L1_BLOCK_INFO" | jq -r '.timestamp')
L1_TIMESTAMP_HEX=$(printf "0x%x" "$L1_TIMESTAMP")

log "  L1 Block Number: $L1_BLOCK_TAG ($L1_BLOCK_TAG_HEX)"
log "  L1 Timestamp: $L1_TIMESTAMP ($L1_TIMESTAMP_HEX)"

# Compute batch inbox address from chain ID
BATCH_INBOX=$(printf "0xff%038x" "$L2_CHAIN_ID")

# Generate the deploy config
DEPLOY_CONFIG="$CONTRACTS_DIR/deploy-config/mychain.json"
DEPLOYMENT_OUTFILE="$CONTRACTS_DIR/deployments/mychain/.deploy"
mkdir -p "$(dirname "$DEPLOYMENT_OUTFILE")"

log "Generating deploy config at $DEPLOY_CONFIG..."

cat > "$DEPLOY_CONFIG" <<EOCFG
{
    "l1ChainID": $(cast chain-id --rpc-url "$L1_RPC_URL" 2>/dev/null || echo 97),
    "l2ChainID": $L2_CHAIN_ID,
    "l2BlockTime": 3,
    "maxSequencerDrift": 600,
    "sequencerWindowSize": 57600,
    "channelTimeout": 1200,
    "p2pSequencerAddress": "$GS_SEQUENCER_ADDRESS",
    "batchInboxAddress": "$BATCH_INBOX",
    "batchSenderAddress": "$GS_BATCHER_ADDRESS",
    "cliqueSignerAddress": "0x0000000000000000000000000000000000000000",
    "l1UseClique": false,
    "l1StartingBlockTag": "$L1_BLOCK_TAG_HEX",
    "l2OutputOracleSubmissionInterval": 3600,
    "l2OutputOracleStartingBlockNumber": 0,
    "l2OutputOracleStartingTimestamp": $L1_TIMESTAMP,
    "l2OutputOracleProposer": "$GS_PROPOSER_ADDRESS",
    "l2OutputOracleChallenger": "$GS_ADMIN_ADDRESS",
    "l2GenesisBlockGasLimit": "0x5f5e100",
    "l1BlockTime": 3,
    "baseFeeVaultMinimumWithdrawalAmount": "0x8ac7230489e80000",
    "l1FeeVaultMinimumWithdrawalAmount": "0x8ac7230489e80000",
    "sequencerFeeVaultMinimumWithdrawalAmount": "0x8ac7230489e80000",
    "baseFeeVaultWithdrawalNetwork": 0,
    "l1FeeVaultWithdrawalNetwork": 0,
    "sequencerFeeVaultWithdrawalNetwork": 0,
    "proxyAdminOwner": "$GS_ADMIN_ADDRESS",
    "baseFeeVaultRecipient": "$GS_ADMIN_ADDRESS",
    "l1FeeVaultRecipient": "$GS_ADMIN_ADDRESS",
    "sequencerFeeVaultRecipient": "$GS_ADMIN_ADDRESS",
    "finalSystemOwner": "$GS_ADMIN_ADDRESS",
    "superchainConfigGuardian": "$GS_ADMIN_ADDRESS",
    "finalizationPeriodSeconds": 604800,
    "fundDevAccounts": false,
    "l2GenesisBlockBaseFeePerGas": "0x5F5E100",
    "gasPriceOracleOverhead": 2100,
    "gasPriceOracleScalar": 1000000,
    "gasPriceOracleBaseFeeScalar": 1368,
    "gasPriceOracleBlobBaseFeeScalar": 810949,
    "enableGovernance": true,
    "governanceTokenSymbol": "MAN",
    "governanceTokenName": "Matrix AI Network",
    "governanceTokenOwner": "$GS_ADMIN_ADDRESS",
    "eip1559Denominator": 8,
    "eip1559DenominatorCanyon": 8,
    "eip1559Elasticity": 2,
    "l1GenesisBlockTimestamp": "$L1_TIMESTAMP_HEX",
    "l2GenesisRegolithTimeOffset": "0x0",
    "l2GenesisDeltaTimeOffset": "0x0",
    "l2GenesisCanyonTimeOffset": "0x0",
    "systemConfigStartBlock": 0,
    "requiredProtocolVersion": "0x0000000000000000000000000000000000000000000000000000000000000000",
    "recommendedProtocolVersion": "0x0000000000000000000000000000000000000000000000000000000000000000",
    "faultGameAbsolutePrestate": "0x03c7ae758795765c6664a5d39bf63841c71ff191e9189522bad8ebff5d4eca98",
    "faultGameMaxDepth": 50,
    "faultGameClockExtension": 0,
    "faultGameMaxClockDuration": 1200,
    "faultGameGenesisBlock": 0,
    "faultGameGenesisOutputRoot": "0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF",
    "faultGameSplitDepth": 14,
    "faultGameWithdrawalDelay": 604800,
    "preimageOracleMinProposalSize": 10000,
    "preimageOracleChallengePeriod": 120,
    "proofMaturityDelaySeconds": 12,
    "disputeGameFinalityDelaySeconds": 6,
    "respectedGameType": 254,
    "useFaultProofs": false,
    "usePlasma": false,
    "daCommitmentType": "KeccakCommitment",
    "daChallengeWindow": 160,
    "daResolveWindow": 160,
    "daBondSize": 1000000,
    "daResolverRefundPercentage": 0,
    "customGasTokenAddress": "$CUSTOM_GAS_TOKEN_ADDRESS",
    "fermat": 0,
    "L2GenesisEcotoneTimeOffset": "0x0",
    "l2GenesisFjordTimeOffset": "0x0",
    "snowTimeOffset": "0x0",
    "haberTimeOffset": "0x0",
    "wrightTimeOffset": "0x0"
}
EOCFG

log "Deploy config generated."

# Deploy L1 contracts
log ""
log "=== Deploying L1 Smart Contracts ==="

cd "$CONTRACTS_DIR"

cat > .env <<EOENV
DEPLOYMENT_OUTFILE=$DEPLOYMENT_OUTFILE
DEPLOY_CONFIG_PATH=$DEPLOY_CONFIG
EOENV

log "Running forge deploy script (this may take several minutes)..."

forge script scripts/Deploy.s.sol:Deploy \
    --private-key "$GS_ADMIN_PRIVATE_KEY" \
    --with-gas-price 1000000000 \
    --broadcast \
    --rpc-url "$L1_RPC_URL" \
    --slow

log ""
log "=== L1 Contract Deployment Complete ==="
log "Deployment artifacts saved to: $DEPLOYMENT_OUTFILE"

# Copy deployment artifacts back
mkdir -p "$ROOT_DIR/deployments"
cp "$DEPLOYMENT_OUTFILE" "$ROOT_DIR/deployments/l1-deploy.json"
log "Artifacts copied to $ROOT_DIR/deployments/l1-deploy.json"

log ""
log "Next: run 04-generate-genesis.sh"
