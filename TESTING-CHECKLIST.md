# MellowPendleVault Testing Checklist

Step-by-step guide to deploy and test the vault system on an Arbitrum fork.

---

## Prerequisites

- [ ] Foundry installed (`forge --version` >= v1.5.0)
- [ ] Arbitrum RPC URL (get free one from [Alchemy](https://www.alchemy.com/) or [Infura](https://infura.io/))
- [ ] A test private key for deploying (any EOA, doesn't need real funds on fork)

---

## Step 1: Environment Setup

### 1.1 Copy and configure environment file

```bash
cp env.example .env
```

### 1.2 Edit `.env` with your values:

```bash
# Required
ARBITRUM_RPC_URL=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY_HERE

# Optional: Use any test private key (fork doesn't need real funds)
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Asset addresses (already set, but verify)
WSTETH=0x5979D7b546E38E414F7E9822514be443A4800529
```

---

## Step 2: Get Real Pendle Addresses for Arbitrum

### 2.1 Visit Pendle documentation

Go to: https://docs.pendle.finance/Developers/Deployments/Arbitrum

### 2.2 Find addresses for:

- **Pendle Router**: Main router contract (should be `0x00000000005BBB0EF59571E58418F9a4357b68A0`)
- **wstETH Market**: Find an active PT-wstETH market (check expiry date!)
- **SY Token**: The Standardized Yield token for that market
- **PT Token**: The Principal Token for that market
- **YT Token**: The Yield Token for that market

### 2.3 Update `ops/config/arbitrum.json`:

```json
{
  "chainId": 42161,
  "name": "arbitrum",
  "comment": "Updated with real Pendle mainnet addresses",
  "WSTETH": "0x5979D7b546E38E414F7E9822514be443A4800529",
  "PENDLE_ROUTER": "0x00000000005BBB0EF59571E58418F9a4357b68A0",
  "PENDLE_MARKET": "0x_ACTUAL_MARKET_ADDRESS_HERE",
  "PENDLE_SY": "0x_ACTUAL_SY_ADDRESS_HERE",
  "PENDLE_PT": "0x_ACTUAL_PT_ADDRESS_HERE",
  "PENDLE_YT": "0x_ACTUAL_YT_ADDRESS_HERE",
  "REWARD_TOKENS": []
}
```

### 2.4 Update environment with Pendle addresses:

```bash
# Add to .env
PENDLE_ROUTER=0x00000000005BBB0EF59571E58418F9a4357b68A0
PENDLE_MARKET=0x_YOUR_MARKET_ADDRESS
PENDLE_SY=0x_YOUR_SY_ADDRESS
PENDLE_PT=0x_YOUR_PT_ADDRESS
PENDLE_YT=0x_YOUR_YT_ADDRESS
```

**Note**: If you can't find a suitable wstETH market, you can use any other market and adjust the `WSTETH` address accordingly. The system works with any ERC20 base asset.

---

## Step 3: Deploy the System

### 3.1 Verify compilation

```bash
forge build
```

Expected: ✅ Compiles successfully (only linter warnings, no errors)

### 3.2 Deploy vault stack

```bash
forge script contracts/script/DeploySystem.s.sol:DeploySystem \
  --fork-url $ARBITRUM_RPC_URL \
  --broadcast \
  --slow
```

### 3.3 Save deployment addresses

From the output, copy these addresses:

```
shareManager: 0x...
feeManager: 0x...
riskManager: 0x...
oracle: 0x...
vault: 0x...              ← IMPORTANT: Save this!
consensus: 0x...
pendleVerifier: 0x...
pendleSubvault: 0x...     ← IMPORTANT: Save this!
```

### 3.4 Export key addresses

```bash
# Add to .env
VAULT_ADDRESS=0x_YOUR_VAULT_ADDRESS_FROM_STEP_3.3
PENDLE_SUBVAULT=0x_YOUR_SUBVAULT_ADDRESS_FROM_STEP_3.3
```

---

## Step 4: Configure the System

### 4.1 Run configuration script

```bash
forge script contracts/script/ConfigureSystem.s.sol:ConfigureSystem \
  --fork-url $ARBITRUM_RPC_URL \
  --sig "run(address)" $VAULT_ADDRESS \
  --broadcast \
  --slow
```

This sets up:
- ✅ Verifier allowlist (Pendle router methods)
- ✅ RiskManager limits & allowed assets
- ✅ Initial oracle price report
- ✅ FeeManager base asset

Expected: ✅ "Configured vault" message at the end

---

## Step 5: Update Test Files with Deployed Addresses

### 5.1 Edit `contracts/test/Fork_SignatureDepositRedeem.t.sol`

Find the `setUp()` function and update:

```solidity
function setUp() public {
    string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc"));
    vm.createSelectFork(rpc);

    deployer = address(this);
    userPrivateKey = 0xA11CE;
    user = vm.addr(userPrivateKey);

    // 🔴 REPLACE THESE WITH YOUR DEPLOYED ADDRESSES FROM STEP 3.3
    vault = Vault(payable(vm.envAddress("VAULT_ADDRESS")));
    wstETH = vm.envAddress("WSTETH");
    
    // Get deposit/redeem queue addresses from vault
    // (Queues are at indices 0 and 1 in the vault's queue list)
    // You may need to manually set these or query them
    
    // 🔴 REMOVE THIS LINE:
    // vm.skip(true);
}
```

**Alternative approach**: Instead of hardcoding, load from environment:

```solidity
function setUp() public {
    string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc"));
    vm.createSelectFork(rpc);

    vault = Vault(payable(vm.envAddress("VAULT_ADDRESS")));
    wstETH = vm.envAddress("WSTETH");
    
    deployer = address(this);
    userPrivateKey = 0xA11CE;
    user = vm.addr(userPrivateKey);

    // TODO: Get queue addresses from vault
    // For now, skip these tests until we implement queue address lookup
    vm.skip(true); // Keep skipped for now - requires queue address lookup
}
```

### 5.2 Edit `contracts/test/Fork_Pendle_EnterExit.t.sol`

Update the `setUp()` function:

```solidity
function setUp() public {
    string memory rpc = vm.envOr(
        "ARBITRUM_RPC_URL",
        string("https://arb1.arbitrum.io/rpc")
    );
    vm.createSelectFork(rpc);

    keeper = address(this);

    // 🔴 REPLACE WITH YOUR DEPLOYED ADDRESSES
    vault = Vault(payable(vm.envAddress("VAULT_ADDRESS")));
    pendleSubvault = PendleSubvault(vm.envAddress("PENDLE_SUBVAULT"));
    wstETH = vm.envAddress("WSTETH");
    pendleRouter = vm.envAddress("PENDLE_ROUTER");
    pendleMarket = vm.envAddress("PENDLE_MARKET");
    
    // 🔴 REMOVE THIS LINE TO ENABLE TESTS:
    // vm.skip(true);
}
```

---

## Step 6: Run the Tests

### 6.1 Test Pendle enter/exit flow (main test)

```bash
forge test --match-contract Fork_Pendle_EnterExit --fork-url $ARBITRUM_RPC_URL -vvv
```

Expected tests:
- ✅ `testPushLiquidityToSubvault` - Vault can push assets to subvault
- ✅ `testEnterPendle` - Keeper can enter Pendle positions
- ✅ `testExitPendle` - Keeper can exit Pendle positions
- ✅ `testPullLiquidityFromSubvault` - Vault can pull assets back
- ✅ `testAccessControl` - Non-keeper cannot call enter/exit
- ✅ `testAssetConservation` - Full cycle preserves assets (within slippage)

### 6.2 Test signature deposit/redeem (advanced)

**Note**: This test requires additional setup (consensus signer, queue addresses). You can skip for initial testing.

```bash
# Only run if you've fully configured signature queues
forge test --match-contract Fork_SignatureDepositRedeem --fork-url $ARBITRUM_RPC_URL -vvv
```

---

## Step 7: Manual Testing with Cast (Optional)

### 7.1 Give vault some wstETH to test with

```bash
# On Arbitrum fork, impersonate a wstETH whale
WSTETH_WHALE=0x... # Find a holder from Arbiscan

cast rpc anvil_impersonateAccount $WSTETH_WHALE

cast send $WSTETH \
  --from $WSTETH_WHALE \
  "transfer(address,uint256)" \
  $VAULT_ADDRESS \
  1000000000000000000  # 1 wstETH
```

### 7.2 Push assets to subvault

```bash
cast send $VAULT_ADDRESS \
  --private-key $PRIVATE_KEY \
  "pushAssets(address,address,uint256)" \
  $PENDLE_SUBVAULT \
  $WSTETH \
  500000000000000000  # 0.5 wstETH
```

### 7.3 Check subvault balance

```bash
cast call $WSTETH "balanceOf(address)(uint256)" $PENDLE_SUBVAULT
```

### 7.4 Encode Pendle router calldata (advanced)

```bash
# Example: Add liquidity to Pendle market
# You'll need to encode the exact method signature for your market
cast calldata "addLiquiditySingleToken(address,address,uint256,uint256,(uint256,uint256,uint256,uint256,uint256))" \
  $PENDLE_SUBVAULT \
  $PENDLE_MARKET \
  0 \
  500000000000000000 \
  "(0,0,0,0,0)"  # Approx params - adjust for real usage
```

---

## Troubleshooting

### ❌ "Stack too deep" error
**Solution**: Already fixed with `via_ir = true` in foundry.toml

### ❌ "vm.skip(true)" - Tests don't run
**Solution**: Complete Step 5 (update test addresses) and remove `vm.skip(true)` lines

### ❌ "VerificationFailed" when calling `enter()`
**Cause**: Router calldata not in verifier allowlist
**Solution**: Check that `ConfigureSystem` ran successfully. Verify the exact function selector matches.

### ❌ "Forbidden" when calling `enter()`
**Cause**: Caller doesn't have `KEEPER_ROLE`
**Solution**: Ensure you're calling with the deployer address (has all roles by default)

### ❌ Test fails: "Vault should receive assets"
**Cause**: Fork doesn't have wstETH in vault yet
**Solution**: Use Step 7.1 to fund the vault with wstETH first, OR modify test to deal wstETH directly

### ❌ "Invalid market" or Pendle call reverts
**Cause**: Wrong Pendle market address or router calldata
**Solution**: 
1. Verify Pendle addresses from docs.pendle.finance
2. Check market is not expired (PT maturity date)
3. Use correct router method signatures

---

## Success Criteria

You'll know the system is working when:

1. ✅ `forge build` compiles without errors
2. ✅ `DeploySystem` script completes and outputs addresses
3. ✅ `ConfigureSystem` script completes successfully
4. ✅ At least `testAccessControl` passes (proves roles work)
5. ✅ `testPushLiquidityToSubvault` passes (proves vault ↔ subvault flow works)

**Ideal goal**: All 6 tests in `Fork_Pendle_EnterExit` pass (full integration working)

---

## Next Steps After Testing

Once tests pass:

- [ ] Review [docs/threat-model.md](docs/threat-model.md) security considerations
- [ ] Plan role transfer to multi-sig (see README "Roles" section)
- [ ] Consider migrating to oracle-based queues (Milestone 2)
- [ ] Set up monitoring/alerting for production deployment
- [ ] Get external audit before mainnet deployment

---

## Quick Reference Commands

```bash
# Build
forge build

# Deploy
forge script contracts/script/DeploySystem.s.sol:DeploySystem --fork-url $ARBITRUM_RPC_URL --broadcast

# Configure
forge script contracts/script/ConfigureSystem.s.sol:ConfigureSystem --fork-url $ARBITRUM_RPC_URL --sig "run(address)" $VAULT_ADDRESS --broadcast

# Test
forge test --match-contract Fork_Pendle_EnterExit --fork-url $ARBITRUM_RPC_URL -vvv

# Check wstETH balance of subvault
cast call $WSTETH "balanceOf(address)(uint256)" $PENDLE_SUBVAULT --rpc-url $ARBITRUM_RPC_URL
```

---

**Need help?** Check the main [README.md](README.md) or [docs/architecture.md](docs/architecture.md) for more details.

