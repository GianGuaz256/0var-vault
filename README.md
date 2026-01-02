# MellowPendleVault

Integrated vault system combining Mellow Core Vaults with Pendle yield strategies on Arbitrum.

## What It Does

- **Single-asset vault** (wstETH) with instant deposit/redeem via signature queues
- **Pendle strategy integration** through permissioned Subvault (enter/exit Pendle positions)
- **Strict security** via verifier allowlists and approval hygiene
- **Fork-tested** on Arbitrum with comprehensive test suite

## Quick Start

### Prerequisites

- Foundry (>= v1.5.0)
- Arbitrum RPC URL

### Installation

```bash
git clone --recurse-submodules https://github.com/GianGuaz256/0var-vault.git
cd 0var-vault
cp env.example .env
# Edit .env with your ARBITRUM_RPC_URL
```

### Build

```bash
forge build
```

### Deploy & Test

See **[TESTING-CHECKLIST.md](TESTING-CHECKLIST.md)** for step-by-step instructions.

**Quick commands:**

```bash
# Deploy system
forge script contracts/script/DeploySystem.s.sol:DeploySystem \
  --fork-url $ARBITRUM_RPC_URL --broadcast

# Configure (use vault address from deploy output)
forge script contracts/script/ConfigureSystem.s.sol:ConfigureSystem \
  --fork-url $ARBITRUM_RPC_URL --sig "run(address)" $VAULT_ADDRESS --broadcast

# Run tests
forge test --match-contract Fork_Pendle_EnterExit --fork-url $ARBITRUM_RPC_URL -vvv
```

## Documentation

- **[TESTING-CHECKLIST.md](TESTING-CHECKLIST.md)** - Step-by-step testing guide
- **[docs/architecture.md](docs/architecture.md)** - System design and data flows
- **[docs/threat-model.md](docs/threat-model.md)** - Security analysis

## License

MIT
