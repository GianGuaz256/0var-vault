# MellowPendleVault Threat Model

## Executive Summary

This document identifies security risks and mitigation strategies for the MellowPendleVault MVP, which integrates Mellow Core Vaults with Pendle protocol strategies.

**Trust Assumptions (MVP)**:
- Deployer is trusted (controls proxies, roles, verifier allowlist)
- Trusted signer for signature queues (co-signs deposit/redeem orders)
- Keeper is trusted (executes enter/exit strategies)

**Future Hardening**: Multi-sig governance, oracle decentralization, strategy parameter guards.

---

## Threat Categories

### 1. External Call Safety

#### Threat: Unrestricted External Calls
**Description**: If `PendleSubvault` could call arbitrary contracts, an attacker with keeper role could drain assets.

**Mitigation**:
- ✅ **Verifier allowlist** (ONCHAIN_COMPACT): Only whitelisted `(who, where, selector)` tuples allowed
- ✅ **CallModule pattern**: All external calls go through `CallModule.call()` → `verifier.verifyCall()`
- ✅ **Immutable targets**: `pendleRouter`, `pendleMarket` set at deploy-time; cannot be changed

**Residual Risk**: Verifier allowlist must be carefully configured; missing selectors = DoS; extra selectors = attack surface.

**Action Items**:
- [ ] Audit verifier allowlist in `ConfigureSystem.s.sol`
- [ ] Document all Pendle router methods used
- [ ] Test that non-allowlisted calls revert

---

#### Threat: Malicious Router Calldata
**Description**: Keeper encodes `routerCalldata` off-chain; could encode malicious parameters (e.g., recipient = attacker).

**Mitigation**:
- ⚠️ **Partial**: Verifier checks `(who, where, selector)` but NOT calldata arguments
- ⚠️ **Trust assumption**: Keeper is trusted (MVP)

**Future Hardening**:
- [ ] Use `BitmaskVerifier` or `MERKLE_EXTENDED` to validate calldata arguments
- [ ] Restrict recipient addresses in router calls to `address(this)` via custom verifier
- [ ] Multi-sig for keeper role

---

### 2. Approval Safety

#### Threat: Infinite Approvals
**Description**: If approvals are not reset, a compromised router could drain future deposits.

**Mitigation**:
- ✅ **Exact approvals**: `_safeApprove(token, spender, value)` approves exact amount
- ✅ **Approval reset**: `_safeApprove(token, spender, 0)` after each use
- ✅ **Internal helpers**: `_safeApprove` and `_safeTransfer` in `PendleSubvault`

**Residual Risk**: If reset fails (e.g., non-standard ERC20), approval remains.

**Action Items**:
- [x] Use SafeERC20 patterns
- [ ] Test with non-standard tokens (USDT, etc.)

---

### 3. Oracle Manipulation

#### Threat: Price Oracle Front-Running
**Description**: Signature queues (MVP) rely on trusted signer to enforce fair pricing; signer could sign unfair orders.

**Mitigation (MVP)**:
- ⚠️ **Trusted signer**: Deployer co-signs all orders; assumed honest
- ⚠️ **Deviation checks**: Oracle (if configured) validates `priceD18` against `maxRelativeDeviationD18`

**Future Hardening**:
- [ ] Migrate to `DepositQueue`/`RedeemQueue` with decentralized oracle reporting
- [ ] Multi-sig for oracle submitter role
- [ ] Chainlink/Pyth price feeds for external validation

**Action Items**:
- [ ] Document signer key management (cold storage, rotation)
- [ ] Monitor signed orders for suspicious prices

---

#### Threat: Stale Prices
**Description**: If oracle reports are delayed, users could arbitrage stale NAV.

**Mitigation (Price-Based Queues)**:
- ✅ **Timeout parameter**: Oracle rejects reports submitted too frequently
- ✅ **Deposit/Redeem intervals**: Minimum age for queue items before processing

**MVP Status**: Signature queues bypass oracle; no timeout enforced.

---

### 4. Queue DoS / Gas Bounds

#### Threat: Unbounded Queue Processing
**Description**: Large queue backlogs could cause out-of-gas errors during `handleReport()`.

**Mitigation**:
- ✅ **Queue limit**: `queueLimit` (default 10) caps total queues per vault
- ✅ **Bounded loops**: Mellow Core Vaults use bounded iteration (queue count, asset count)

**Residual Risk**: If many users deposit, individual queue items accumulate; batch processing may still hit gas limits.

**Action Items**:
- [ ] Monitor queue sizes
- [ ] Test gas usage with 100+ pending orders

---

### 5. Accounting Mismatch

#### Threat: Share/Asset Accounting Drift
**Description**: If fees, hooks, or subvault NAV are miscalculated, share price diverges from underlying asset value.

**Mitigation**:
- ✅ **Mellow Core Vaults audit**: Share accounting audited by Nethermind (202508, 202510, 202511)
- ✅ **RiskManager limits**: Prevents over-allocation to subvaults
- ✅ **totalHoldings()**: PendleSubvault reports liquid balance (MVP); future: include Pendle position NAV

**Residual Risk**: `totalHoldings()` currently only returns liquid wstETH; Pendle LP/PT value not included.

**Future Hardening**:
- [ ] Integrate Pendle oracle for LP/PT valuation
- [ ] Off-chain accounting bot verifies share price
- [ ] Automated alerts for NAV drift >1%

---

### 6. Maturity Risk (Pendle Specific)

#### Threat: PT Converges at Expiry
**Description**: Pendle Principal Tokens (PT) converge to 1:1 with underlying at maturity; liquidity/slippage changes dramatically near expiry.

**Mitigation (MVP)**:
- ⚠️ **Manual management**: Keeper monitors expiry and exits positions before maturity
- ⚠️ **Slippage checks**: `minAssetOut` parameter in `exit()` prevents unexpected losses

**Future Hardening**:
- [ ] Automated expiry monitoring (keeper bot checks `block.timestamp` vs maturity)
- [ ] Strategy parameter: `minDaysToExpiry` (refuse enter if < N days)
- [ ] Gradual exit (unwind 50% at expiry - 7 days, 100% at expiry - 1 day)

**Action Items**:
- [ ] Document Pendle market expiry dates
- [ ] Keeper runbook: "Exit all positions 7 days before expiry"

---

### 7. Access Control

#### Threat: Role Escalation
**Description**: If non-admin gains `DEFAULT_ADMIN_ROLE`, they can grant themselves all permissions and drain vault.

**Mitigation**:
- ✅ **Mellow ACL**: Uses OpenZeppelin `AccessControl` with explicit role hierarchy
- ✅ **Role review**: `DeploySystem.s.sol` grants deployer all roles (explicit, auditable)

**Residual Risk**: Deployer private key compromise = total loss.

**Future Hardening**:
- [ ] Transfer admin to multi-sig (Gnosis Safe, 3-of-5)
- [ ] Timelock for critical operations (role grants, proxy upgrades)

**Action Items**:
- [ ] Document role holders in README
- [ ] Rotate deployer keys post-deployment

---

#### Threat: Keeper Malice
**Description**: Keeper could execute unfavorable `enter/exit` (e.g., high slippage, wrong market).

**Mitigation**:
- ⚠️ **Trust assumption**: Keeper is trusted (MVP)
- ✅ **Slippage bounds**: `minLpOut`, `minAssetOut` parameters prevent extreme losses
- ✅ **Verifier**: Restricts targets to `pendleRouter` only

**Future Hardening**:
- [ ] Multi-sig for keeper role (2-of-3 execution)
- [ ] Strategy parameter review: admin-set max slippage (e.g., 1%)
- [ ] Off-chain monitoring: alert if enter/exit exceeds expected slippage

---

### 8. Upgradability Risks

#### Threat: Malicious Upgrade
**Description**: ProxyAdmin could upgrade to malicious implementation that steals assets.

**Mitigation**:
- ✅ **Transparent proxy**: ProxyAdmin cannot call vault functions (only upgrade)
- ✅ **Namespaced storage**: Mellow uses EIP-7201 slots; reduces storage collision risk

**Residual Risk**: ProxyAdmin holder = total control.

**Future Hardening**:
- [ ] Transfer ProxyAdmin to multi-sig + timelock (48h delay)
- [ ] Public upgrade announcements + community review period

---

### 9. Signature Replay / Nonce Issues

#### Threat: Replay Attacks
**Description**: Attacker replays signed order to execute twice.

**Mitigation**:
- ✅ **Nonce tracking**: `SignatureQueue` increments `nonces[caller]` after each order
- ✅ **EIP-712 domain**: Includes `chainId`, contract address, version
- ✅ **Deadline**: Orders expire (`block.timestamp > deadline` → revert)

**Residual Risk**: If nonce is not incremented (bug in queue logic), replay possible.

**Action Items**:
- [x] Mellow Core Vaults audit covers nonce logic
- [ ] Test: submit same order twice → second reverts with `InvalidNonce`

---

### 10. Pendle Protocol Risks (External)

#### Threat: Pendle Router Exploit
**Description**: If Pendle router is exploited, assets in transit could be stolen.

**Mitigation**:
- ✅ **Approval hygiene**: Approvals reset to 0 after use; limits exposure window
- ✅ **Asset custody**: Assets only exposed during `enter/exit` execution (atomic transaction)

**Residual Risk**: If Pendle router is compromised mid-transaction, that batch of assets at risk.

**Future Monitoring**:
- [ ] Subscribe to Pendle security alerts
- [ ] Pause/emergencyExit if Pendle incident reported

---

#### Threat: Pendle Market Insolvency
**Description**: Pendle market liquidity dries up; LP tokens become un-redeemable.

**Mitigation**:
- ⚠️ **Market selection**: Choose high-TVL, liquid Pendle markets
- ⚠️ **Diversification**: (Future) spread across multiple markets

**Residual Risk**: Black swan event = partial loss.

**Action Items**:
- [ ] Monitor Pendle market TVL (require >$10M)
- [ ] Diversify across 3+ markets (future milestone)

---

## Risk Matrix

| Threat | Likelihood | Impact | Severity | Mitigation Status |
|--------|------------|--------|----------|-------------------|
| Unrestricted External Calls | Low | Critical | High | ✅ Mitigated (verifier) |
| Malicious Router Calldata | Medium (if keeper compromised) | High | Medium-High | ⚠️ Trust assumption |
| Infinite Approvals | Low | High | Medium | ✅ Mitigated (reset pattern) |
| Oracle Front-Running | Medium (trusted signer) | Medium | Medium | ⚠️ Trust assumption |
| Queue DoS | Low | Medium | Low-Medium | ✅ Mitigated (limits) |
| Accounting Drift | Low | Medium | Medium | ✅ Audited (Mellow) |
| PT Maturity Risk | Medium | Medium | Medium | ⚠️ Manual management |
| Role Escalation | Low (key mgmt) | Critical | High | ⚠️ Single-key MVP |
| Keeper Malice | Low (trusted) | High | Medium | ⚠️ Trust assumption |
| Malicious Upgrade | Low (key mgmt) | Critical | High | ⚠️ Single-key MVP |
| Signature Replay | Low | Medium | Low | ✅ Mitigated (nonce) |
| Pendle Router Exploit | Low (external) | High | Medium | ✅ Minimal exposure |
| Pendle Market Insolvency | Low | High | Medium | ⚠️ Market selection |

**Legend**:
- ✅ Mitigated: Technical controls in place
- ⚠️ Partial / Trust assumption: Relies on operational security or trusted parties
- ❌ Unmitigated: Known risk, no control (document & accept)

---

## Recommendations

### MVP → Production Checklist

1. **Governance**:
   - [ ] Transfer `DEFAULT_ADMIN_ROLE` to multi-sig (3-of-5 Gnosis Safe)
   - [ ] Add timelock for proxy upgrades (48h delay)

2. **Oracle**:
   - [ ] Migrate from `SignatureDepositQueue` to `DepositQueue` (oracle-based)
   - [ ] Deploy oracle submitter with multi-sig or decentralized bot

3. **Strategy Automation**:
   - [ ] Keeper bot with automated maturity monitoring
   - [ ] Max slippage parameters set by admin (e.g., 1%)
   - [ ] Multi-sig for keeper role (2-of-3)

4. **Monitoring**:
   - [ ] Dashboard: TVL, APY, subvault allocation, share price
   - [ ] Alerts: NAV drift >1%, Pendle security incidents, role changes
   - [ ] Monthly review: verifier allowlist, role holders, market liquidity

5. **Audits**:
   - [ ] External audit of `PendleSubvault.sol` (focus: verifier config, approval hygiene)
   - [ ] Formal verification of approval reset logic

6. **Documentation**:
   - [ ] Incident response playbook (emergency pause, exit, recovery)
   - [ ] User guide: deposit/redeem, expected APY, risks

---

## Emergency Procedures

### Scenario 1: Pendle Router Compromised
1. **Immediate**: Pause all keeper operations (do not call `enter/exit`)
2. **Assess**: Check if any assets in PendleSubvault are exposed
3. **Action**: Call `emergencyExit()` (admin) to unwind positions at best-effort
4. **Communicate**: Notify users, pause deposits via `setQueueStatus(queue, true)`

### Scenario 2: Deployer Key Compromised
1. **Immediate**: If attacker has not yet acted, emergency multi-sig takeover (requires pre-planned backup admin)
2. **Assess**: Review all role grants, proxy upgrades in last 24h
3. **Action**: Revoke attacker's roles, pause vault, forensics
4. **Recovery**: Deploy new vault, migrate assets via social recovery or snapshot

### Scenario 3: Oracle Manipulation Detected
1. **Immediate**: Pause oracle submissions (`SUBMIT_REPORTS_ROLE` revoked)
2. **Assess**: Compare reported prices vs external feeds (Chainlink, Coingecko)
3. **Action**: If manipulation confirmed, reject suspicious reports, re-submit correct prices
4. **Harden**: Migrate to decentralized oracle network

---

## References

- [Mellow Core Vaults Audit (Nethermind)](https://github.com/mellow-finance/flexible-vaults/tree/main/audits)
- [Pendle Security Docs](https://docs.pendle.finance)
- [OpenZeppelin Upgradeable Contracts](https://docs.openzeppelin.com/upgrades-plugins)
