# MellowPendleVault Architecture

## Overview

MellowPendleVault integrates **Mellow Core Vaults** (flexible-vaults) as the vault infrastructure with a **Pendle strategy Subvault** to generate yield through Pendle fixed-rate and LP positions.

## System Components

```
┌─────────────────────────────────────────────────────────────────┐
│                         User Layer                               │
│  ┌────────────┐        ┌────────────┐       ┌────────────┐     │
│  │  Depositor │───────▶│SignatureDepositQueue│  Redeemer │     │
│  └────────────┘        └────────────┘       └────────────┘     │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Vault Layer (Core)                          │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                        Vault                              │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │  │
│  │  │ShareManager │  │ FeeManager  │  │RiskManager  │     │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘     │  │
│  │  ┌─────────────┐  ┌─────────────┐                       │  │
│  │  │   Oracle    │  │  ACLModule  │                       │  │
│  │  └─────────────┘  └─────────────┘                       │  │
│  └──────────────────────┬───────────────────────────────────┘  │
└─────────────────────────┼───────────────────────────────────────┘
                          │ VaultModule.pushAssets()
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Strategy Layer                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                  PendleSubvault                           │  │
│  │  ┌──────────────────────────────────────────────────┐   │  │
│  │  │  - enter(): Deploy wstETH into Pendle positions  │   │  │
│  │  │  - exit():  Unwind positions back to wstETH      │   │  │
│  │  │  - sweep(): Emergency asset recovery (admin)     │   │  │
│  │  │  - totalHoldings(): Report asset value           │   │  │
│  │  └──────────────────────────────────────────────────┘   │  │
│  │                                                           │  │
│  │  ┌──────────────────────────────────────────────────┐   │  │
│  │  │         Verifier (Access Control)                 │   │  │
│  │  │  - ONCHAIN_COMPACT allowlist                      │   │  │
│  │  │  - Restricts: who, where, selector                │   │  │
│  │  └──────────────────────────────────────────────────┘   │  │
│  └──────────────────────┬────────────────────────────────────┘  │
└─────────────────────────┼────────────────────────────────────────┘
                          │ CallModule.call() → verifier.verifyCall()
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Pendle Protocol (External)                  │
│  ┌───────────────┐    ┌──────────────┐    ┌────────────────┐  │
│  │ Pendle Router │───▶│ Pendle Market│───▶│ SY / PT / YT   │  │
│  └───────────────┘    └──────────────┘    └────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Core Contracts

### 1. Vault (Mellow Core)
- **Inherited from**: `mellow/vaults/Vault.sol`
- **Composition**: ShareModule + VaultModule + ACLModule
- **Responsibilities**:
  - Share accounting (mint/burn)
  - Asset routing to subvaults
  - Role-based access control
  - Queue management (deposit/redeem)

### 2. PendleSubvault
- **Location**: `contracts/src/subvaults/PendleSubvault.sol`
- **Inherits**: Mellow `Subvault` (CallModule + SubvaultModule)
- **State**:
  - Immutables: `asset`, `pendleRouter`, `pendleMarket`, `pendleSY`, `pendlePT`, `pendleYT`, `vault`
  - Role: `KEEPER_ROLE` (can call `enter/exit`)
- **Functions**:
  - `enter(uint256 amountAsset, uint256 minLpOut, bytes calldata routerCalldata)`:
    - Pulls `asset` from parent vault
    - Approves Pendle router
    - Executes router call (add liquidity)
  - `exit(uint256 lpAmount, uint256 minAssetOut, bytes calldata routerCalldata)`:
    - Executes router call (remove liquidity)
    - Returns `asset` to parent vault
  - `sweep(address token, address to, uint256 amount)`:
    - Admin-only emergency recovery (excludes `asset` and Pendle position tokens)

### 3. Verifier
- **Type**: Mellow `Verifier` (configured via ONCHAIN_COMPACT allowlist)
- **Purpose**: Restricts external calls from `PendleSubvault` to whitelisted targets/selectors
- **Allowlist** (set in `ConfigureSystem.s.sol`):
  - `(pendleSubvault, pendleRouter, addLiquiditySingleToken.selector)`
  - `(pendleSubvault, pendleRouter, removeLiquiditySingleToken.selector)`
  - `(pendleSubvault, wstETH, approve.selector)`
  - `(pendleSubvault, wstETH, transfer.selector)`
  - Additional selectors as needed for Pendle interactions

### 4. SignatureDepositQueue / SignatureRedeemQueue
- **Inherited from**: Mellow Core Vaults
- **Purpose**: Instant deposit/redeem with trusted signer approval (no oracle wait)
- **Consensus**: Multi-sig or single trusted signer (deployer for MVP)
- **Flow**:
  1. User signs EIP-712 order (orderId, asset, amounts, deadline, nonce)
  2. Trusted signer co-signs
  3. Anyone can submit order + signatures to execute

## Data Flows

### Deposit Flow
```
User
  │ 1. Approve wstETH to SignatureDepositQueue
  ├─▶ IERC20(wstETH).approve(depositQueue, amount)
  │
  │ 2. Sign order (EIP-712)
  ├─▶ orderHash = depositQueue.hashOrder(order)
  ├─▶ signature = sign(userPrivateKey, orderHash)
  │
  │ 3. Submit deposit (with trusted signer co-signature)
  ├─▶ depositQueue.deposit(order, [userSig, trustedSig])
  │     ├─▶ TransferLibrary.receiveAssets(wstETH, user, amount)
  │     ├─▶ TransferLibrary.sendAssets(wstETH, vault, amount)
  │     ├─▶ vault.shareManager().mint(user, shares)
  │     └─▶ (optional) vault.callHook() → VaultModule.pushAssets(pendleSubvault, ...)
  │
  └─▶ User receives shares
```

### Enter Pendle Flow
```
Keeper
  │ 1. Decide allocation amount
  ├─▶ VaultModule.pushAssets(pendleSubvault, wstETH, amount)
  │     ├─▶ RiskManager.modifySubvaultBalance(+amount)
  │     └─▶ TransferLibrary.sendAssets(wstETH, pendleSubvault, amount)
  │
  │ 2. Encode Pendle router calldata (off-chain)
  ├─▶ routerCalldata = abi.encodeWithSelector(...)
  │
  │ 3. Execute enter
  ├─▶ pendleSubvault.enter(amount, minLpOut, routerCalldata)
  │     ├─▶ IERC20(wstETH).approve(pendleRouter, amount)
  │     ├─▶ CallModule.call(pendleRouter, 0, routerCalldata, verificationPayload)
  │     │     └─▶ verifier.verifyCall(...) → check allowlist
  │     ├─▶ (Pendle router executes → returns LP/PT/YT tokens to pendleSubvault)
  │     └─▶ IERC20(wstETH).approve(pendleRouter, 0) [reset approval]
  │
  └─▶ PendleSubvault holds Pendle position tokens
```

### Exit Pendle Flow
```
Keeper
  │ 1. Encode exit calldata
  ├─▶ routerCalldata = abi.encodeWithSelector(removeLiquidity...)
  │
  │ 2. Execute exit
  ├─▶ pendleSubvault.exit(lpAmount, minAssetOut, routerCalldata)
  │     ├─▶ CallModule.call(pendleRouter, 0, routerCalldata, verificationPayload)
  │     │     └─▶ verifier.verifyCall(...) → check allowlist
  │     └─▶ (Pendle router redeems LP → wstETH returned to pendleSubvault)
  │
  └─▶ PendleSubvault holds liquid wstETH
```

### Redeem Flow
```
User
  │ 1. Sign redeem order (EIP-712)
  ├─▶ orderHash = redeemQueue.hashOrder(order)
  ├─▶ signature = sign(userPrivateKey, orderHash)
  │
  │ 2. Submit redeem
  ├─▶ redeemQueue.redeem(order, [userSig, trustedSig])
  │     ├─▶ Check vault liquid balance
  │     ├─▶ (if insufficient) VaultModule.pullAssets(pendleSubvault, wstETH, needed)
  │     │     ├─▶ pendleSubvault.pullAssets(wstETH, vault, amount)
  │     │     └─▶ RiskManager.modifySubvaultBalance(-amount)
  │     ├─▶ vault.shareManager().burn(user, shares)
  │     └─▶ TransferLibrary.sendAssets(wstETH, user, amount)
  │
  └─▶ User receives wstETH
```

## Key Design Decisions

### 1. Calldata Passthrough
**Rationale**: Keeps Solidity code minimal; router interactions evolve rapidly.
- `enter/exit` accept `bytes calldata routerCalldata`
- Off-chain scripts encode Pendle router calls
- Verifier enforces allowlist (target + selector)

### 2. Approval Hygiene
**Implementation**: Approve exact amount, reset to 0 after use
- `_safeApprove(token, spender, value)` → approve exact
- `_safeApprove(token, spender, 0)` → reset
- Prevents infinite approval accumulation

### 3. Signature Queues (MVP)
**Why**: Simplifies MVP; no oracle bot required
- Instant UX for testnet/fork
- Trusted signer (deployer) co-signs orders
- Production upgrade: migrate to `DepositQueue`/`RedeemQueue` with full oracle reporting

### 4. Single-Asset Vault
**Current**: wstETH only
**Rationale**: Simplifies NAV calculation, reduces oracle complexity
**Future**: Multi-asset support requires per-asset oracle feeds + complex accounting

## Roles & Permissions

| Role | Holder | Capabilities |
|------|--------|--------------|
| `DEFAULT_ADMIN_ROLE` | Deployer | Grant/revoke all roles, upgrade proxies |
| `CREATE_QUEUE_ROLE` | Deployer | Create new deposit/redeem queues |
| `CREATE_SUBVAULT_ROLE` | Deployer | Create new subvaults |
| `PUSH_LIQUIDITY_ROLE` | Keeper | Push assets from vault to subvaults |
| `PULL_LIQUIDITY_ROLE` | Keeper | Pull assets from subvaults to vault |
| `KEEPER_ROLE` (PendleSubvault) | Keeper | Execute `enter/exit` on PendleSubvault |
| `ORACLE_SUBMIT_REPORTS_ROLE` | Oracle bot | Submit price reports (for price-based queues) |
| `VERIFIER_ALLOW_CALL_ROLE` | Admin | Add/remove verifier allowlist entries |
| `RM_ALLOW_SUBVAULT_ASSETS_ROLE` | Admin | Allow new assets per subvault |
| `RM_SET_SUBVAULT_LIMIT_ROLE` | Admin | Set max allocation per subvault |

## Upgradability

All core contracts (Vault, Subvault, managers, oracle) are deployed as **TransparentUpgradeableProxy**:
- ProxyAdmin: Controlled by deployer (MVP)
- Implementation: Upgradable via `ProxyAdmin.upgrade()`
- Storage: Uses namespaced storage slots (EIP-7201 pattern via Mellow's `SlotLibrary`)

**Production recommendation**: Transfer ProxyAdmin to a multi-sig or governance timelock.

## Testing Strategy

### Fork Tests (MVP)
1. **Fork_SignatureDepositRedeem.t.sol**
   - Test deposit → shares minted
   - Test redeem → assets returned
   - Signature validation

2. **Fork_Pendle_EnterExit.t.sol**
   - Test pushAssets → subvault receives wstETH
   - Test enter → Pendle position acquired
   - Test exit → wstETH returned
   - Test pullAssets → vault receives wstETH
   - Access control tests (non-keeper reverts)
   - Asset conservation (full cycle)

### Future Tests
- Price-based queue flows (oracle reports)
- Multi-market Pendle strategies
- Emergency exit scenarios
- Fuzz tests (slippage, amounts, timestamps)

## Dependencies

- **Mellow Core Vaults** (`lib/flexible-vaults`): Vault infrastructure
- **OpenZeppelin Upgradeable**: Proxy + utilities
- **Pendle Protocol**: External (router, markets, SY/PT/YT tokens)

## Deployment Addresses (Arbitrum)

See [`ops/config/arbitrum.json`](../ops/config/arbitrum.json) for:
- wstETH: `0x5979D7b546E38E414F7E9822514be443A4800529`
- Pendle Router, Market, SY, PT, YT: Update with actual addresses before production
