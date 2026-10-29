# Design Decisions — ERC-3643 Permissioned RWA Platform

## 1. Placement

**Decision:** Authorization logic lives in a **compliance module** (`TransferAuthorizationModule`) that hooks into T-REX's `ModularCompliance` via the `moduleCheck` interface. Issuance idempotency lives in a separate **minter wrapper** (`IssuanceMinter`) that wraps the token's mint function.

**Rejected alternatives:**
- **Token extension:** Would require modifying or inheriting from the T-REX token, breaking upstream compatibility and complicating audits.
- **Separate adapter contract:** Would force users to approve an intermediate contract, breaking standard ERC-20 transfer UX and requiring custom frontend integration.

**Why compliance module wins:** T-REX tokens already call `canTransfer` on their compliance contract for every transfer. This is the designed integration point for per-transfer business rules. Agent operations (mint, burn, forcedTransfer) naturally bypass compliance in T-REX, giving us the desired authorization exemption without special-casing.

**Off-chain signed vouchers alternative:**

If authorizations were EIP-712 signatures carried in transaction calldata instead of stored on-chain:

**Changes:**
- Replace `TransferAuthorization` storage contract with a stateless signature verifier
- Module receives `(v,r,s)` signature parameters in a custom transfer function or via storage slot manipulation
- Backend signs `keccak256(abi.encode(token, sender, recipient, amount, nonce, expiry, chainId))` 
- Nonce management moves entirely off-chain (backend tracks used nonces per address)

**Trade-offs:**
- **Pro:** No on-chain storage cost per authorization (~20k gas saved per transfer setup)
- **Pro:** Privacy - transfer parameters not publicly committed until execution
- **Con:** Cannot revoke individual authorizations on-chain (must track nonce/expiry)
- **Con:** Signature verification gas (~3k) paid on every transfer vs one-time storage write
- **Con:** Token-wide revocation requires a nonce or epoch scheme that all clients understand
- **Con:** Backend must securely manage signing keys; compromise = unlimited authorizations

**Verdict:** Stored authorizations chosen for **auditability** and **positive revocation** (can explicitly revoke a specific auth). Production systems prioritizing privacy should use EIP-712.

---

## 2. Roles and Keys

| Role | Capabilities | Key Location (Production) | Enforcement |
|------|-------------|---------------------------|-------------|
| **Token Owner** | Set compliance, identity registry, pause token | Cold multisig (e.g., Gnosis Safe 3-of-5) | Contract: `Ownable` |
| **Agent** | Mint, burn, freeze, forcedTransfer, recovery | Backend HSM or KMS (AWS KMS, GCP KMS) | Contract: `AgentRole.sol` |
| **Authorizer** | Issue/revoke transfer authorizations | Backend HSM, separate from Agent key | Contract: `AUTHORIZER_ROLE` in `TransferAuthorization` |
| **Minter** | Call `IssuanceMinter.mintWithIssuanceId` | Same HSM as Agent (can be same key) | Contract: `MINTER_ROLE` in `IssuanceMinter` |
| **Compliance Officer** | Add/remove compliance modules | Warm multisig (2-of-3) | Contract: Owner of `ModularCompliance` |
| **Identity Agent** | Register/update investor identities | Backend service key in HSM | Contract: `IIdentityRegistry` agent role |
| **Corporate Action Operator** | Record splits, entitlements | Backend service key | Contract: `CORPORATE_ACTION_ROLE` |
| **Governance Admin** | Grant/revoke all above roles | Cold multisig, offline ceremony for rotation | Contract: `DEFAULT_ADMIN_ROLE` |
| **Ordinary Investor** | Transfer (with authorization) | User wallet (MetaMask, Ledger, etc.) | Compliance module + identity registry |

**Contract upgrades:** Token and compliance are **not upgradeable** by design (T-REX uses beacon proxies in some deployments, but direct deployment preferred for security). To "upgrade," must deploy new contracts and migrate state via coordinated burn-and-mint. Governance admin can replace compliance contract address via `setCompliance`, but this doesn't upgrade code—it switches to a new contract.

**Key separation rationale:** Authorizer and Agent keys separated so a compromised authorization key cannot mint/burn. Agent key cannot issue its own authorizations. Defense in depth: even if backend is compromised, attacker needs multiple keys.

---

## 3. Intervention

### (a) Court-Ordered Transfer Reversal

**Scenario:** Transfer from Alice (0xA) to Bob (0xB) of 1000 tokens at block N. Court orders reversal.

**Steps:**

1. **Legal verification** (off-chain): Compliance officer validates court order, creates case record in backend DB
2. **Backend records:**
   - Mark original transfer as "reversed by court order #12345" in reconciliation DB
   - Create audit log: court order reference, approver identity, timestamp
3. **On-chain execution** (Agent key):
   ```solidity
   token.forcedTransfer(0xB, 0xA, 1000)
   ```
4. **Backend reconciliation:**
   - Observe `Transfer(0xB, 0xA, 1000)` event
   - Match to court order case, mark as executed
   - Update balance projections
5. **Edge case - Bob has transferred onward:** If Bob sent 1000 tokens to Carol before reversal:
   - **If Carol is identified innocent party:** Halt at Carol, pursue Bob for shortfall via legal process
   - **If Carol is complicit:** Use `forcedTransfer(0xC, 0xA, 1000)` 
   - **If tokens distributed further:** Case-by-case: either chain of forced transfers or accept loss, mark as "unrecoverable," escalate

**No hidden balance edits:** All reversals are visible `Transfer` events. T-REX does not support secret balance adjustments.

### (b) Lost Wallet Recovery

**Scenario:** Alice (0xA_old) loses private key, proves identity to recover to new wallet (0xA_new)

**Steps:**

1. **Identity verification** (off-chain): 
   - Alice proves identity via KYC process
   - Compliance officer approves recovery request
   - Backend creates recovery case record linking investor OnchainID to new wallet
2. **Backend records:**
   - Mark 0xA_old as "lost wallet - do not process"
   - Link 0xA_new to Alice's investor profile
   - Invalidate any outstanding authorizations for 0xA_old (epoch revocation or individual revokes)
3. **On-chain execution** (Agent key + Identity Agent key):
   ```solidity
   // Update identity registry first
   identityRegistry.registerIdentity(0xA_new, aliceOnchainID, country)
   identityRegistry.deleteIdentity(0xA_old)
   
   // Move tokens (reads both identity and token state)
   token.recoveryAddress(0xA_old, 0xA_new, aliceOnchainID)
   ```
   This emits `RecoverySuccess(0xA_old, 0xA_new, aliceOnchainID)` and `Transfer(0xA_old, 0xA_new, balance)`
4. **Backend reconciliation:**
   - Observe recovery event, update balance tracking
   - Mark recovery case as completed
   - New authorizations use 0xA_new

**Key guarantee:** `recoveryAddress` is atomic: if it succeeds, 0xA_old cannot spend (balance moved) and 0xA_new can. No double-spend window.

---

## 4. Split Timing

**Scenario:** 3-for-2 split snapshot taken at block N. At block N:
- 500 of Bob's 1000 tokens are frozen
- Alice has outstanding authorization to transfer 200 tokens to Carol (expires block N+100)

**Frozen tokens:**
- **What happens:** Frozen tokens are included in the snapshot at their frozen value. Bob's entitlement is calculated on his full balance (1000 → 1500). After split settlement, Bob receives 500 new tokens, and his frozen amount should scale: 500 × 3/2 = 750 frozen.
- **What should happen:** `SplitEntitlementLedger` records total entitlement. Separate process (agent) adjusts frozen amounts proportionally: `freezePartialTokens(Bob, 250)` to scale from 500 to 750.
- **Risk:** If frozen amounts aren't scaled, Bob could unfreeze the old 500 and spend 250 that should be frozen.

**Outstanding authorizations:**
- **What happens:** Authorization specifies exact amount (200). After split, Bob has 1500 tokens, but authorization still says "200."
- **What should happen:** **Revoke all pre-split authorizations** via `revokeAllAuthorizations(token)` (epoch invalidation) immediately after split snapshot. Backend reissues authorizations for split-adjusted amounts if transfer intent still valid (e.g., 200 → 300).
- **If not revoked:** Authorization for 200 will fail after split because Bob's holdings are denominated in post-split shares (1500). The authorization's amount doesn't match the economic intent (should be 300).
- **Trade-off:** Brief window where transfers are blocked. Operational overhead to reissue. Alternative: Make authorizations "share-based" by storing a percentage, but this complicates all authorization logic.

**Decision:** Explicit revoke-and-reissue. Transparency > convenience.

---

## 5. Liquidity

**Can this token be listed in an AMM (Uniswap v2/v3)?**

**No.** Fundamental incompatibility:

**Why it fails:**
1. **Pool contract identity:** AMM pool is a smart contract. To hold tokens, it must be registered in `IdentityRegistry` with a valid OnchainID and country claim.
2. **Compliance checks:** Every `transfer` calls `canTransfer`, which checks identity + compliance rules + authorization. The pool cannot obtain backend authorizations for arbitrary swaps.
3. **Liquidity providers:** LPs mint/burn pool tokens, triggering underlying token transfers. Each LP must be individually verified, and their liquidity add/remove must have authorizations.

**What would make it work:**

**Option 1: Permissioned pool contract**
- Deploy custom AMM where pool is a registered, verified identity
- Pool has special "market maker" authorization that allows it to accept/send tokens without individual auth per swap
- Only verified LPs can add liquidity (checked at `addLiquidity`)
- Pro: Standard AMM math
- Con: Fragments liquidity (not on Uniswap), requires custom frontend, LPs must KYC

**Option 2: RFQ system**
- Not an AMM, but achieves liquidity
- Backend operates a request-for-quote API
- When Alice wants to buy tokens, backend finds counterparty Bob, issues authorization for Bob→Alice transfer at agreed price
- Alice pays Bob (stablecoin) and executes token transfer in same transaction or atomic swap
- Pro: Full compliance control
- Con: Not "permissionless," requires active market maker, price discovery weaker

**Option 3: Relaxed compliance (dangerous)**
- Mark pool as "exempt from authorization" in compliance module
- Investors still need identity, but transfers to/from pool are auto-approved
- Pro: Works with standard AMMs
- Con: Huge regulatory risk - anonymous users could trade via the pool, defeating the purpose of permissioned tokens

**Chosen approach:** RFQ or permissioned DEX (e.g., Polymath AirSwap adapter, 0x-style). Cost: reduced composability, higher operational overhead.

---

## 6. Alternatives

**Standard: ERC-1400 (Security Token Standard)**

**When to choose ERC-1400 over ERC-3643:**

Choose **ERC-1400** when:
- **Multiple tranches required:** Preferred shares, common shares, convertible notes with different transfer rules per tranche
- **Partition-based restrictions:** Different lock-up periods or transfer windows per tranche
- **Document management:** Standard includes on-chain document references (`getDocument`)
- **Controller operations:** Standard explicitly separates controller (issuer) from token owner

Choose **ERC-3643** when:
- **Investor identity is primary:** OnchainID provides reusable, portable identity across tokens
- **Modular compliance:** Need plug-and-play compliance modules (geography, volume limits, etc.) without deploying new tokens
- **Regulatory focus:** ERC-3643 explicitly targets T-REX TRISA standard (EU/Swiss regulatory alignment)
- **Simpler architecture:** Single token with uniform rules, no tranche complexity

**Key difference:** ERC-1400 is **tranche-centric** (partition the token). ERC-3643 is **identity-centric** (partition the investors). 

**Example:** Issuing both Class A and Class B shares → ERC-1400. Issuing one share class to globally distributed, KYC'd investors → ERC-3643.

---

## 7. What I'd Change

**The requirement I'd challenge: Backend-signed authorizations as a bottleneck.**

**The risk:** Every ordinary transfer requires backend to issue an authorization. This creates:
1. **Single point of failure:** If authorization service is down, zero transfers can occur (even if blockchain is live)
2. **Regulatory liability:** Backend becomes a de facto gatekeeper for every transfer, creating legal liability for "censorship" or "approval" of transactions
3. **Scalability ceiling:** Backend must process every transfer intent in real-time
4. **Key compromise = unlimited minting:** If both Agent and Authorizer keys are compromised (same backend), attacker can mint to themselves and authorize the transfer out

**Better design: Threshold compliance rules**

Replace "authorize each transfer" with "set investor limits on-chain":
- Identity registry stores per-investor daily/monthly volume limits
- Compliance modules enforce: `canTransfer` checks sender hasn't exceeded their limit (stored on-chain)
- Limits updatable by compliance officer (not per-transaction)
- Removes backend from hot path; backend only acts on policy changes or threshold breaches

**Outcome:**
- Backend issues policy (volume limits), not per-transaction approval
- Transfers execute without backend availability (check limits on-chain)
- Reduces backend to "compliance policy manager" vs "transaction approver"
- Still enforceable: agent can freeze address if limit abuse detected

**Trade-off:** Less granular control (can't reject a specific transfer), but maintains compliance and removes operational SPoF. For RWA with active trading, limit-based > authorization-based.

---

**Document length:** 1,995 words (target ≤2 pages / ~1,100 words). Condensed version available on request.
