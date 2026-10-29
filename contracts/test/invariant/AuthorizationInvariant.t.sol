// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "../Base.t.sol";

/**
 * @title AuthorizationInvariantTest
 * @author Permissioned RWA Platform
 * @notice Stateful invariant tests for the authorization system.
 * @dev Uses a handler contract to fuzz valid state transitions, then checks invariants.
 *
 * ─── WHY THESE INVARIANTS MATTER ────────────────────────────────────────────
 *
 * 1. NO_DOUBLE_CONSUMPTION: The core safety property. If an authorization can be
 *    consumed twice, an attacker could drain the token by replaying a single auth.
 *    This invariant protects the single-use guarantee (R2).
 *
 * 2. REVOKED_NEVER_USABLE: Once revoked (individually or via epoch), an auth must
 *    never validate again. If revocation could be bypassed, the backend loses its
 *    ability to cancel erroneous or suspicious authorizations. This protects R4.
 *
 * 3. EXPIRED_NEVER_USABLE: Expiry (R3) is a time-based revocation. If expired auths
 *    could be used, stale permissions would persist indefinitely, violating the
 *    backend's temporal control over transfers.
 *
 * 4. CONSUMED_AUTH_CLEARED_FROM_SLOT: The active slot must be cleared on consumption
 *    so a fresh authorization can be issued for the same tuple. If not cleared, the
 *    slot would block new issuances, creating a denial-of-service.
 *
 * 5. TOKEN_SUPPLY_CONSERVATION: Sum of balances always equals total supply. This is
 *    a general ERC-20 invariant, but we verify it holds through authorization
 *    consumption, forced transfers, mints, and burns.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 */
contract AuthorizationInvariantTest is BaseTest {
    AuthorizationHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new AuthorizationHandler(s, backend, alice, bob, carol);

        // Seed alice with tokens for the handler to work with
        s.minter.mintWithIssuanceId(alice, 10_000e18, keccak256("invariant-seed"));

        // Target the handler for invariant fuzzing
        targetContract(address(handler));
    }

    // ──────────────────────────────────────────── INVARIANT 1: NO_DOUBLE_CONSUMPTION
    // WHY: The fundamental safety property. Prevents replay attacks and double-spends.

    /// @custom:invariant No authorization can be consumed twice.
    function invariant_NoDoubleConsumption() public view {
        bytes32[] memory consumed = handler.getConsumedAuths();
        for (uint256 i = 0; i < consumed.length; i++) {
            assertTrue(
                s.authorization.getAuthorization(consumed[i]).consumed,
                "consumed auth marked"
            );
            assertFalse(
                s.authorization.isValid(consumed[i], address(s.token), alice, bob, 100e18),
                "consumed auth not valid"
            );
        }
    }

    // ──────────────────────────────────────────── INVARIANT 2: REVOKED_NEVER_USABLE
    // WHY: Backend must retain revocation authority. Bypassing revocation breaks incident response.

    /// @custom:invariant Revoked authorizations (individual or epoch) can never validate.
    function invariant_RevokedNeverUsable() public view {
        bytes32[] memory revoked = handler.getRevokedAuths();
        for (uint256 i = 0; i < revoked.length; i++) {
            ITransferAuthorization.Authorization memory auth = s.authorization.getAuthorization(revoked[i]);
            if (auth.token == address(0)) continue; // not issued, skip

            bool isRevokedIndividually = auth.revoked;
            bool isRevokedByEpoch = auth.issuedAtEpoch < s.authorization.tokenEpoch(auth.token);

            if (isRevokedIndividually || isRevokedByEpoch) {
                assertFalse(
                    s.authorization.isValid(revoked[i], auth.token, auth.sender, auth.recipient, auth.amount),
                    "revoked auth never valid"
                );
            }
        }
    }

    // ──────────────────────────────────────────── INVARIANT 3: EXPIRED_NEVER_USABLE
    // WHY: Temporal control is critical for compliance. Expired auths must be strictly rejected.

    /// @custom:invariant Expired authorizations can never be consumed.
    function invariant_ExpiredNeverUsable() public view {
        bytes32[] memory issued = handler.getIssuedAuths();
        for (uint256 i = 0; i < issued.length; i++) {
            ITransferAuthorization.Authorization memory auth = s.authorization.getAuthorization(issued[i]);
            if (auth.token == address(0)) continue;

            if (block.timestamp > auth.expiry) {
                assertFalse(
                    s.authorization.isValid(issued[i], auth.token, auth.sender, auth.recipient, auth.amount),
                    "expired auth not valid"
                );
            }
        }
    }

    // ──────────────────────────────────────────── INVARIANT 4: CONSUMED_AUTH_CLEARED_FROM_SLOT
    // WHY: Prevents denial-of-service. A consumed auth must free the slot for a new issuance.

    /// @custom:invariant Consumed authorizations clear their active slot.
    function invariant_ConsumedAuthClearedFromSlot() public view {
        bytes32[] memory consumed = handler.getConsumedAuths();
        for (uint256 i = 0; i < consumed.length; i++) {
            ITransferAuthorization.Authorization memory auth = s.authorization.getAuthorization(consumed[i]);
            if (auth.token == address(0)) continue;

            bytes32 activeId = s.authorization.activeAuthIdFor(
                auth.token, auth.sender, auth.recipient, auth.amount
            );

            // The consumed auth should not be the active one (slot cleared)
            if (activeId != bytes32(0)) {
                assertTrue(activeId != consumed[i], "consumed auth cleared from slot");
            }
        }
    }

    // ──────────────────────────────────────────── INVARIANT 5: TOKEN_SUPPLY_CONSERVATION
    // WHY: General ERC-20 safety. Sum of balances must equal total supply at all times.

    /// @custom:invariant sum(balances) == totalSupply
    function invariant_TokenSupplyConservation() public view {
        uint256 sumBalances = s.token.balanceOf(alice)
            + s.token.balanceOf(bob)
            + s.token.balanceOf(carol)
            + s.token.balanceOf(address(handler)); // handler might hold tokens

        assertEq(sumBalances, s.token.totalSupply(), "supply conservation");
    }

    // ──────────────────────────────────────────── call summary (for debugging)

    function invariant_callSummary() public view {
        handler.printSummary();
    }
}

/**
 * @title AuthorizationHandler
 * @notice Fuzzing handler that performs valid state transitions on the authorization system.
 * @dev The fuzzer calls these functions with random inputs. We track issued/consumed/revoked
 *      authorizations to verify invariants.
 */
contract AuthorizationHandler {
    DeployBase.Suite internal s;
    address internal backend;
    address internal alice;
    address internal bob;
    address internal carol;

    bytes32[] internal issuedAuths;
    bytes32[] internal consumedAuths;
    bytes32[] internal revokedAuths;

    uint256 internal issueCount;
    uint256 internal transferCount;
    uint256 internal revokeCount;
    uint256 internal epochRevokeCount;
    uint256 internal mintCount;
    uint256 internal burnCount;

    constructor(DeployBase.Suite memory _s, address _backend, address _alice, address _bob, address _carol) {
        s = _s;
        backend = _backend;
        alice = _alice;
        bob = _bob;
        carol = _carol;
    }

    // ──────────────────────────────────────────── handler actions

    /// @notice Issue a new authorization (as backend).
    function issueAuth(uint256 nonce, uint256 amount, uint256 expiryOffset) public {
        amount = bound(amount, 1, 1000e18);
        expiryOffset = bound(expiryOffset, 1 hours, 30 days);

        uint256 expiry = block.timestamp + expiryOffset;
        bytes32 authId = s.authorization.computeAuthId(address(s.token), alice, bob, amount, expiry, nonce);

        // Check if already issued
        if (s.authorization.getAuthorization(authId).token != address(0)) return;

        // Check if slot is occupied
        bytes32 active = s.authorization.activeAuthIdFor(address(s.token), alice, bob, amount);
        if (active != bytes32(0)) return;

        vm.prank(backend);
        try s.authorization.issueAuthorization(authId, address(s.token), alice, bob, amount, expiry) {
            issuedAuths.push(authId);
            issueCount++;
        } catch {
            // Issue failed (duplicate, expired, etc.) — skip
        }
    }

    /// @notice Attempt a transfer with an active authorization.
    function transfer(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        // Check if authorization exists
        bytes32 authId = s.authorization.activeAuthIdFor(address(s.token), alice, bob, amount);
        if (authId == bytes32(0)) return;

        // Check if alice has enough balance
        if (s.token.balanceOf(alice) < amount) return;

        vm.prank(alice);
        try s.token.transfer(bob, amount) {
            consumedAuths.push(authId);
            transferCount++;
        } catch {
            // Transfer failed (expired, revoked, frozen, etc.) — skip
        }
    }

    /// @notice Revoke a single authorization.
    function revokeAuth(uint256 index) public {
        if (issuedAuths.length == 0) return;
        index = bound(index, 0, issuedAuths.length - 1);

        bytes32 authId = issuedAuths[index];
        ITransferAuthorization.Authorization memory auth = s.authorization.getAuthorization(authId);

        if (auth.consumed || auth.revoked) return;

        vm.prank(backend);
        try s.authorization.revokeAuthorization(authId) {
            revokedAuths.push(authId);
            revokeCount++;
        } catch {
            // Already revoked or consumed
        }
    }

    /// @notice Revoke all authorizations via epoch bump.
    function revokeAllAuths() public {
        vm.prank(backend);
        s.authorization.revokeAllAuthorizations(address(s.token));

        // Mark all issued auths as revoked
        for (uint256 i = 0; i < issuedAuths.length; i++) {
            revokedAuths.push(issuedAuths[i]);
        }
        epochRevokeCount++;
    }

    /// @notice Mint tokens (bypasses authorization).
    function mint(address recipient, uint256 amount, uint256 nonce) public {
        amount = bound(amount, 1, 1000e18);
        if (recipient == address(0)) recipient = alice;

        bytes32 issuanceId = keccak256(abi.encode("handler-mint", nonce));
        if (s.minter.usedIssuanceIds(issuanceId)) return;

        try s.minter.mintWithIssuanceId(recipient, amount, issuanceId) {
            mintCount++;
        } catch {
            // Mint failed (paused, not registered, etc.)
        }
    }

    /// @notice Burn tokens (bypasses authorization).
    function burn(address from, uint256 amount) public {
        amount = bound(amount, 1, 1000e18);
        if (from == address(0)) from = alice;

        uint256 balance = s.token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        try s.token.burn(from, amount) {
            burnCount++;
        } catch {
            // Burn failed (paused, etc.)
        }
    }

    /// @notice Warp time forward (to test expiry).
    function warpTime(uint256 delta) public {
        delta = bound(delta, 1 minutes, 7 days);
        vm.warp(block.timestamp + delta);
    }

    // ──────────────────────────────────────────── views

    function getIssuedAuths() external view returns (bytes32[] memory) {
        return issuedAuths;
    }

    function getConsumedAuths() external view returns (bytes32[] memory) {
        return consumedAuths;
    }

    function getRevokedAuths() external view returns (bytes32[] memory) {
        return revokedAuths;
    }

    function printSummary() external view {
        console.log("=== Authorization Handler Summary ===");
        console.log("Issued:", issueCount);
        console.log("Transfers:", transferCount);
        console.log("Revocations (individual):", revokeCount);
        console.log("Revocations (epoch):", epochRevokeCount);
        console.log("Mints:", mintCount);
        console.log("Burns:", burnCount);
        console.log("=====================================");
    }
}
