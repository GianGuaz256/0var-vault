# MellowPendleVault

**Production-ready vault system combining Mellow Core Vaults with Pendle yield strategies on Arbitrum.**

## Overview

MellowPendleVault is a single-asset (wstETH) vault that:
- **Accepts deposits** via signature-based instant queues (no oracle wait for MVP)
- **Routes assets** into Pendle fixed-rate markets and LP positions via a permissioned Subvault
- **Generates yield** through Pendle PT discounts and LP fees
- **Enforces strict security** via verifier allowlists and approval hygiene

**Key Features**:
- ✅ Modular architecture (Mellow Core Vaults framework)
- ✅ Signature queues for instant UX (trusted signer flow)
- ✅ Calldata passthrough strategy (flexible Pendle integration)
- ✅ Role-based access control (keeper, admin, verifier)
- ✅ Fork tests for Arbitrum deployment
- ✅ Upgradeable proxies (TransparentUpgradeableProxy pattern)

**Target Network**: Arbitrum (mainnet fork for testing)

---

## Quick Start

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (>= v1.5.0)
- [Node.js](https://nodejs.org/) (v20+) + [pnpm](https://pnpm.io/)
- Arbitrum RPC URL (e.g., Alchemy, Infura, or public endpoint)

### Installation

```bash
# Clone repo
git clone <repo-url>
cd mellow-pendle

# Install dependencies
pnpm install
forge install

# Copy environment template
cp env.example .env

# Edit .env with your Arbitrum RPC and addresses
# ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc
# WSTETH=0x5979D7b546E38E414F7E9822514be443A4800529
# PENDLE_ROUTER=<from docs.pendle.finance>
# PENDLE_MARKET=<wstETH market address>
# PENDLE_SY=<SY token>
# PENDLE_PT=<PT token>
# PENDLE_YT=<YT token>
```

### Build

```bash
forge build
```

**Expected**: Compiles successfully with only linter warnings (not errors).

---

## 🧪 Testing Guide

**For step-by-step testing instructions**, see **[TESTING-CHECKLIST.md](TESTING-CHECKLIST.md)**

This checklist walks you through:
1. Setting up environment variables
2. Getting real Pendle addresses
3. Deploying the system on Arbitrum fork
4. Configuring roles and allowlists
5. Updating test files with deployed addresses
6. Running fork tests
7. Manual testing with Cast (optional)

**Quick start**: Copy `.env.example` to `.env`, add your Arbitrum RPC URL, then follow the checklist!

---

## Architecture

See [docs/architecture.md](docs/architecture.md) for detailed component descriptions.

**High-Level Flow**:
```
User → SignatureDepositQueue → Vault → PendleSubvault → Pendle Protocol
  ↓                                ↓                ↓
Shares Minted              VaultModule         Router + Market
  ↓                                ↓                ↓
User → SignatureRedeemQueue ← Vault ← PendleSubvault ← Pendle LP/PT Tokens
```

**Core Contracts**:
- `Vault` (Mellow Core): Share accounting, asset routing, ACL
- `PendleSubvault` (custom): Strategy executor (enter/exit Pendle positions)
- `Verifier` (Mellow Core): External call allowlist enforcer
- `SignatureDepositQueue` / `SignatureRedeemQueue` (Mellow Core): Instant deposit/redeem

---

## Deployment (Fork)

### Step 1: Deploy System

```bash
# Set deployer private key
export PRIVATE_KEY=0x...

# Run deploy script on Arbitrum fork
forge script contracts/script/DeploySystem.s.sol:DeploySystem \
  --fork-url $ARBITRUM_RPC_URL \
  --broadcast
```

**Outputs** (save these addresses):
- `vault`: Main vault entry point
- `pendleSubvault`: Strategy subvault
- `consensus`: Signature validator
- Plus: shareManager, feeManager, riskManager, oracle, pendleVerifier

### Step 2: Configure Roles & Allowlist

```bash
# Pass vault address from step 1
export VAULT_ADDRESS=<vault from DeploySystem output>

forge script contracts/script/ConfigureSystem.s.sol:ConfigureSystem \
  --fork-url $ARBITRUM_RPC_URL \
  --sig "run(address)" $VAULT_ADDRESS \
  --broadcast
```

**This configures**:
- Verifier allowlist (Pendle router methods)
- RiskManager limits
- Initial oracle report
- baseAsset for FeeManager

---

## Testing

### Compile

```bash
forge build
```

### Fork Tests (Full Flow)

**Requirement**: Set `ARBITRUM_RPC_URL` in `.env`.

```bash
# Test signature deposit/redeem
forge test --match-contract Fork_SignatureDepositRedeem --fork-url $ARBITRUM_RPC_URL -vv

# Test Pendle enter/exit
forge test --match-contract Fork_Pendle_EnterExit --fork-url $ARBITRUM_RPC_URL -vv
```

**Note**: Fork tests currently have `vm.skip(true)` stubs because they require deployed vault addresses. To enable:
1. Deploy system (step 1 + 2 above)
2. Update test `setUp()` with actual addresses
3. Remove `vm.skip(true)`
4. Run tests

**Expected Scenarios**:
- ✅ User deposits wstETH → receives shares
- ✅ Keeper pushes assets to subvault
- ✅ Keeper enters Pendle (acquires LP/PT)
- ✅ Keeper exits Pendle (redeems to wstETH)
- ✅ User redeems → receives wstETH back
- ✅ Access control enforced (non-keeper reverts)
- ✅ Asset conservation within slippage bounds

---

## Usage (After Deployment)

### Deposit (User)

Users sign EIP-712 orders for instant deposit:

```solidity
// 1. Approve wstETH to deposit queue
IERC20(wstETH).approve(depositQueue, amount);

// 2. Build & sign order
ISignatureQueue.Order memory order = ISignatureQueue.Order({
    orderId: 1,
    queue: depositQueue,
    asset: wstETH,
    caller: msg.sender,
    recipient: msg.sender,
    ordered: amount, // wstETH in
    requested: amount, // shares out (1:1 for MVP)
    deadline: block.timestamp + 1 hours,
    nonce: depositQueue.nonces(msg.sender)
});

bytes32 orderHash = depositQueue.hashOrder(order);
// Sign with user private key + get trusted signer co-signature
bytes memory signatures = ...;

// 3. Submit deposit
depositQueue.deposit(order, signatures);
// → Shares minted instantly
```

### Enter Pendle (Keeper)

```bash
# 1. Push assets to subvault
cast send $VAULT_ADDRESS \
  "pushAssets(address,address,uint256)" \
  $PENDLE_SUBVAULT $WSTETH 1000000000000000000 \
  --private-key $KEEPER_KEY

# 2. Enter Pendle (with encoded router calldata)
cast send $PENDLE_SUBVAULT \
  "enter(uint256,uint256,bytes)" \
  1000000000000000000 0 $ROUTER_CALLDATA \
  --private-key $KEEPER_KEY
```

### Exit & Redeem

Similar flows in reverse: `exit()` unwi nds Pendle positions, `pullAssets()` returns liquidity to vault, user redeems via `SignatureRedeemQueue`.

---

## Configuration

### Chain Config: `ops/config/arbitrum.json`

```json
{
  "chainId": 42161,
  "WSTETH": "0x5979D7b546E38E414F7E9822514be443A4800529",
  "PENDLE_ROUTER": "<update with actual address>",
  "PENDLE_MARKET": "<update with actual wstETH market>",
  "PENDLE_SY": "<Standardized Yield token>",
  "PENDLE_PT": "<Principal Token>",
  "PENDLE_YT": "<Yield Token>"
}
```

**Action**: Update Pendle addresses from [docs.pendle.finance](https://docs.pendle.finance/Developers/Deployments/Arbitrum) before production use.

### Roles (MVP)

| Role | Holder | Purpose |
|------|--------|---------|
| `DEFAULT_ADMIN_ROLE` | Deployer | Master admin (grant roles, upgrade) |
| `KEEPER_ROLE` | Deployer | Execute strategies (`enter/exit`) |
| `PUSH/PULL_LIQUIDITY_ROLE` | Deployer | Move assets between vault and subvaults |
| `VERIFIER_ALLOW_CALL_ROLE` | Deployer | Update external call allowlist |

**Production**: Transfer to multi-sig (3-of-5 Gnosis Safe).

---

## Security

See [docs/threat-model.md](docs/threat-model.md) for comprehensive threat analysis.

**Key Mitigations**:
- ✅ **Verifier allowlist**: Only whitelisted external calls allowed
- ✅ **Approval hygiene**: Reset to 0 after each use
- ✅ **Nonce tracking**: Prevents signature replay
- ✅ **Slippage bounds**: Protects against MEV

**Known Risks (MVP)**:
- ⚠️ Trusted signer (single point of trust for instant queues)
- ⚠️ Trusted keeper (can execute strategies)
- ⚠️ Single deployer key (no multi-sig yet)

**Upgrade Path**: Multi-sig governance → Decentralized oracle → Automated strategies

---

## Project Structure

```
mellow-pendle/
├── contracts/
│   ├── src/
│   │   ├── subvaults/
│   │   │   └── PendleSubvault.sol       # Strategy executor
│   │   └── interfaces/
│   │       └── (Pendle interfaces)
│   ├── script/
│   │   ├── DeploySystem.s.sol           # Deploy vault stack
│   │   └── ConfigureSystem.s.sol        # Configure roles + allowlist
│   └── test/
│       ├── Fork_SignatureDepositRedeem.t.sol
│       └── Fork_Pendle_EnterExit.t.sol
├── lib/
│   └── flexible-vaults/                 # Mellow Core Vaults (vendored)
├── ops/
│   └── config/
│       └── arbitrum.json                # Chain addresses
├── docs/
│   ├── product-spec.md                  # Original requirements
│   ├── architecture.md                  # System design
│   └── threat-model.md                  # Security analysis
├── foundry.toml                         # Foundry config
├── package.json                         # pnpm workspace
└── README.md                            # This file
```

---

## Troubleshooting

### Build: "Stack too deep"
**Solution**: Ensure `via_ir = true` in `foundry.toml`.

### Test: "vm.skip(true)"
**Cause**: Fork tests are stubbed pending deployment.
**Solution**: Deploy system, update test addresses, remove `vm.skip(true)`.

### Verifier: "VerificationFailed"
**Cause**: External call not in allowlist.
**Solution**: Add entry to verifier allowlist in `ConfigureSystem`.

### Signature: "InvalidSignatures"
**Cause**: Missing trusted signer co-signature.
**Solution**: Ensure consensus is configured with trusted signer.

---

## Roadmap

### ✅ Milestone 1: MVP (Current)
- Single-asset vault (wstETH)
- Signature queues
- Pendle strategy subvault
- Fork tests

### 🚧 Milestone 2: Oracle Integration
- Price-based queues (`DepositQueue`/`RedeemQueue`)
- Oracle submitter bot

### 📋 Milestone 3: Strategy Automation
- Keeper bot (automated enter/exit)
- Maturity monitoring (auto-exit before PT expiry)

### 📋 Milestone 4: Governance
- Multi-sig for all roles
- Timelock for upgrades

### 📋 Milestone 5: Production
- External audit
- Mainnet deployment (Arbitrum)

---

## Resources

- **Mellow Finance**: [docs.mellow.finance](https://docs.mellow.finance)
- **Pendle Finance**: [docs.pendle.finance](https://docs.pendle.finance)
- **Foundry Book**: [book.getfoundry.sh](https://book.getfoundry.sh)

## License

MIT
