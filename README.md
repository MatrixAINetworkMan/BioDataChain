# MAN L2

A production-ready Layer 1 blockchain independently built and operated by MATRIX, featuring MAN as its native gas token.

## Quick Start

```bash
# 1. Install dependencies & build
./scripts/00-setup-deps.sh

# 2. Generate wallets
./scripts/01-generate-wallets.sh

# 3. Fund wallets on BSC, then deploy token
source config/wallets.env
export L1_RPC_URL="https://data-seed-prebsc-1-s1.bnbchain.org:8545"
./scripts/02-deploy-token.sh

# 4. Deploy L1 contracts
./scripts/03-deploy-l1-contracts.sh

# 5. Generate genesis
./scripts/04-generate-genesis.sh

# 6. Start the chain
./scripts/05-start-sequencer.sh
./scripts/06-start-batcher.sh
./scripts/07-start-proposer.sh

# 7. Check status
./scripts/09-check-status.sh
```

## Architecture

| Component | Role |
|-----------|------|
| **op-geth** | Execution client (EVM, state, tx pool) |
| **op-node** | Consensus client (block ordering from L1) |
| **op-batcher** | Submits tx batches to BSC L1 |
| **op-proposer** | Submits L2 state roots to BSC L1 |
| **MAN Token (MAN)** | ERC-20 on BSC (Matrix AI Network) used as L2 native gas token via CGT v2 |

## Project Structure

```
mychain/
  contracts/        Solidity contracts (MyToken ERC-20)
  config/           Chain configuration & environment templates
  scripts/          Deployment & startup automation
  docker/           Docker Compose production deployment
  monitoring/       Prometheus + Grafana setup
  docs/             Detailed deployment guide
```

## Documentation

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for the full deployment guide.

## Key Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| L2 Chain ID | 42170 | Unique chain identifier |
| L2 Block Time | 3s | Block production interval |
| Total Supply | 2,000,000,000 MAN | Token total supply (Matrix AI Network) |
| Gas Token | MAN | Custom ERC-20 on BSC |
| L1 | BSC (Chain 56/97) | Settlement layer |

## License

MIT
