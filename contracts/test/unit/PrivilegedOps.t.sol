// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "../Base.t.sol";

/**
 * @title PrivilegedOpsTest
 * @author Permissioned RWA Platform
 * @notice Requirement R5: Agent-only operations (mint, burn, freeze, forcedTransfer, recovery)
 *         MUST bypass the authorization module and succeed without a backend-issued authorization.
 * @dev Tests every R5 operation listed in the requirements document, confirming that:
 *       1. The operation succeeds when called by an agent (no authorization needed).
 *       2. The operation reverts when called by a non-agent.
 *       3. Mint goes through IssuanceMinter (which is a token agent) to preserve idempotency.
 */
contract PrivilegedOpsTest is BaseTest {
    uint256 internal constant AMOUNT = 100e18;

    // ---------------------------------------------------------------- R5.1: mint (via IssuanceMinter)

    /// @notice Minting succeeds WITHOUT any authorization. Minter is a token agent.
    function test_Mint_NoAuthorizationRequired() public {
        bytes32 issuanceId = keccak256("mint-test-1");
        uint256 before = s.token.balanceOf(bob);

        // No authorization issued — mint still succeeds
        s.minter.mintWithIssuanceId(bob, AMOUNT, issuanceId);

        assertEq(s.token.balanceOf(bob), before + AMOUNT, "minted successfully");
    }

    /// @notice The module's mint bypass: `from == address(0)` in moduleCheck returns true.
    function test_Mint_BypassesModuleCheck() public {
        // Verify the module returns true for mint path (from == address(0))
        assertTrue(s.module.moduleCheck(address(0), bob, AMOUNT, address(s.mc)), "mint bypass enabled");
    }

    /// @notice Minting as non-agent reverts (IssuanceMinter is owned by test contract, which is agent).
    function test_Mint_RevertsForNonAgent() public {
        IssuanceMinter freshMinter = new IssuanceMinter(address(s.token));
        // freshMinter is not a token agent

        vm.prank(address(this)); // owner of freshMinter
        vm.expectRevert("Role: Sender is not a token agent");
        freshMinter.mintWithIssuanceId(bob, AMOUNT, keccak256("fail"));
    }

    // ---------------------------------------------------------------- R5.2: burn

    /// @notice Agent can burn tokens WITHOUT authorization.
    function test_Burn_NoAuthorizationRequired() public {
        // Seed alice with tokens
        s.minter.mintWithIssuanceId(alice, AMOUNT, keccak256("burn-seed"));

        uint256 before = s.token.balanceOf(alice);
        assertGt(before, 0, "alice has balance");

        // Owner (test contract) is a token agent; burn succeeds without auth
        s.token.burn(alice, AMOUNT);

        assertEq(s.token.balanceOf(alice), before - AMOUNT, "burned successfully");
    }

    /// @notice Burn as non-agent reverts.
    function test_Burn_RevertsForNonAgent() public {
        s.minter.mintWithIssuanceId(alice, AMOUNT, keccak256("burn-fail-seed"));

        vm.prank(bob);
        vm.expectRevert("Role: Sender is not a token agent");
        s.token.burn(alice, AMOUNT);
    }

    // ---------------------------------------------------------------- R5.3: freeze / unfreeze

    /// @notice Agent can freeze address WITHOUT authorization.
    function test_Freeze_NoAuthorizationRequired() public {
        assertFalse(s.token.isFrozen(alice), "alice not frozen initially");

        // Owner (agent) freezes alice
        s.token.setAddressFrozen(alice, true);

        assertTrue(s.token.isFrozen(alice), "alice frozen");
    }

    /// @notice Frozen address cannot transfer even with valid authorization.
    function test_FrozenAddress_CannotTransfer_EvenWithAuthorization() public {
        // Seed alice and authorize a transfer
        s.minter.mintWithIssuanceId(alice, AMOUNT, keccak256("freeze-transfer-seed"));
        _issueAuthOneHour(alice, bob, AMOUNT);

        // Freeze alice
        s.token.setAddressFrozen(alice, true);

        // Transfer reverts despite valid authorization
        vm.prank(alice);
        vm.expectRevert("Transfer not possible");
        s.token.transfer(bob, AMOUNT);
    }

    /// @notice Agent can unfreeze.
    function test_Unfreeze_RestoresTransferAbility() public {
        s.minter.mintWithIssuanceId(alice, AMOUNT, keccak256("unfreeze-seed"));
        s.token.setAddressFrozen(alice, true);
        assertTrue(s.token.isFrozen(alice), "frozen");

        // Unfreeze
        s.token.setAddressFrozen(alice, false);
        assertFalse(s.token.isFrozen(alice), "unfrozen");

        // Now alice can transfer with authorization
        _issueAuthOneHour(alice, bob, AMOUNT);
        _transfer(alice, bob, AMOUNT);
        assertEq(s.token.balanceOf(bob), AMOUNT, "transfer succeeded after unfreeze");
    }

    /// @notice Freeze as non-agent reverts.
    function test_Freeze_RevertsForNonAgent() public {
        vm.prank(bob);
        vm.expectRevert("Role: Sender is not a token agent");
        s.token.setAddressFrozen(alice, true);
    }

    // ---------------------------------------------------------------- R5.4: forcedTransfer

    /// @notice Agent can forcibly move tokens WITHOUT authorization.
    function test_ForcedTransfer_NoAuthorizationRequired() public {
        // Seed alice
        s.minter.mintWithIssuanceId(alice, AMOUNT, keccak256("forced-seed"));

        uint256 aliceBefore = s.token.balanceOf(alice);
        uint256 bobBefore = s.token.balanceOf(bob);

        // Owner (agent) forces transfer from alice to bob WITHOUT authorization
        s.token.forcedTransfer(alice, bob, AMOUNT);

        assertEq(s.token.balanceOf(alice), aliceBefore - AMOUNT, "alice balance reduced");
        assertEq(s.token.balanceOf(bob), bobBefore + AMOUNT, "bob balance increased");
    }

    /// @notice Forced transfer works even if sender is frozen.
    function test_ForcedTransfer_WorksOnFrozenAddress() public {
        s.minter.mintWithIssuanceId(alice, AMOUNT, keccak256("forced-frozen-seed"));
        s.token.setAddressFrozen(alice, true);

        // forcedTransfer succeeds despite freeze
        s.token.forcedTransfer(alice, bob, AMOUNT);

        assertEq(s.token.balanceOf(bob), AMOUNT, "forced transfer succeeded on frozen address");
    }

    /// @notice ForcedTransfer as non-agent reverts.
    function test_ForcedTransfer_RevertsForNonAgent() public {
        s.minter.mintWithIssuanceId(alice, AMOUNT, keccak256("forced-fail-seed"));

        vm.prank(bob);
        vm.expectRevert("Role: Sender is not a token agent");
        s.token.forcedTransfer(alice, bob, AMOUNT);
    }

    // ---------------------------------------------------------------- R5.5: recoveryAddress (wallet recovery)

    /// @notice Agent can recover a lost wallet to a new address WITHOUT authorization.
    function test_RecoveryAddress_NoAuthorizationRequired() public {
        // Seed alice
        s.minter.mintWithIssuanceId(alice, AMOUNT, keccak256("recovery-seed"));

        address recoveredWallet = makeAddr("recoveredWallet");
        _registerInvestor(s, recoveredWallet, COUNTRY_US);

        uint256 aliceBalance = s.token.balanceOf(alice);
        assertGt(aliceBalance, 0, "alice has balance");

        // Owner (agent) initiates wallet recovery
        s.token.recoveryAddress(alice, recoveredWallet, address(this)); // onchainID management key = this

        assertEq(s.token.balanceOf(recoveredWallet), aliceBalance, "balance moved to recovered wallet");
        assertEq(s.token.balanceOf(alice), 0, "alice balance zeroed");
    }

    /// @notice RecoveryAddress as non-agent reverts.
    function test_RecoveryAddress_RevertsForNonAgent() public {
        s.minter.mintWithIssuanceId(alice, AMOUNT, keccak256("recovery-fail-seed"));
        address recoveredWallet = makeAddr("recoveredWallet");
        _registerInvestor(s, recoveredWallet, COUNTRY_US);

        vm.prank(bob);
        vm.expectRevert("Role: Sender is not a token agent");
        s.token.recoveryAddress(alice, recoveredWallet, address(this));
    }

    // ---------------------------------------------------------------- R5.6: pause / unpause

    /// @notice Agent can pause the token, blocking all transfers (including with authorization).
    function test_Pause_BlocksAllTransfers() public {
        s.minter.mintWithIssuanceId(alice, AMOUNT, keccak256("pause-seed"));
        _issueAuthOneHour(alice, bob, AMOUNT);

        // Pause
        s.token.pause();
        assertTrue(s.token.paused(), "token paused");

        // Transfer reverts despite valid authorization
        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        s.token.transfer(bob, AMOUNT);
    }

    /// @notice Agent can unpause, restoring functionality.
    function test_Unpause_RestoresTransfers() public {
        s.minter.mintWithIssuanceId(alice, AMOUNT, keccak256("unpause-seed"));
        s.token.pause();

        // Unpause
        s.token.unpause();
        assertFalse(s.token.paused(), "token unpaused");

        // Now transfers work with authorization
        _issueAuthOneHour(alice, bob, AMOUNT);
        _transfer(alice, bob, AMOUNT);
        assertEq(s.token.balanceOf(bob), AMOUNT, "transfer succeeded after unpause");
    }

    /// @notice Pause as non-agent reverts.
    function test_Pause_RevertsForNonAgent() public {
        vm.prank(bob);
        vm.expectRevert("Role: Sender is not a token agent");
        s.token.pause();
    }

    // ---------------------------------------------------------------- comprehensive R5 verification

    /// @notice INTEGRATION: All R5 operations succeed without any authorization in the registry.
    function test_AllR5Operations_WorkWithoutAuthorization() public {
        // Mint (no auth)
        bytes32 issuanceId = keccak256("r5-integration");
        s.minter.mintWithIssuanceId(alice, AMOUNT, issuanceId);
        assertEq(s.token.balanceOf(alice), AMOUNT, "mint succeeded");

        // Freeze (no auth)
        s.token.setAddressFrozen(alice, true);
        assertTrue(s.token.isFrozen(alice), "freeze succeeded");

        // ForcedTransfer (no auth, works on frozen address)
        s.token.forcedTransfer(alice, bob, AMOUNT / 2);
        assertEq(s.token.balanceOf(bob), AMOUNT / 2, "forced transfer succeeded");

        // Unfreeze (no auth)
        s.token.setAddressFrozen(alice, false);
        assertFalse(s.token.isFrozen(alice), "unfreeze succeeded");

        // Burn (no auth)
        uint256 remaining = s.token.balanceOf(alice);
        s.token.burn(alice, remaining);
        assertEq(s.token.balanceOf(alice), 0, "burn succeeded");

        // Recovery (no auth) — bob has AMOUNT/2, recover to carol
        s.token.recoveryAddress(bob, carol, address(this));
        assertEq(s.token.balanceOf(carol), AMOUNT / 2, "recovery succeeded");
        assertEq(s.token.balanceOf(bob), 0, "bob zeroed");

        // Pause (no auth)
        s.token.pause();
        assertTrue(s.token.paused(), "pause succeeded");

        // Unpause (no auth)
        s.token.unpause();
        assertFalse(s.token.paused(), "unpause succeeded");
    }

    /// @notice Verify that no authorizations were created during R5 operations.
    function test_R5Operations_DoNotConsumeAuthorizations() public {
        // Issue an authorization for a regular transfer
        bytes32 authId = _issueAuthOneHour(alice, bob, AMOUNT);

        // Perform several R5 operations
        s.minter.mintWithIssuanceId(alice, AMOUNT, keccak256("r5-no-consume"));
        s.token.setAddressFrozen(carol, true);
        s.token.setAddressFrozen(carol, false);

        // The authorization is still valid and unconsumed
        assertFalse(_consumed(authId), "auth not consumed by R5 ops");
        assertTrue(
            s.authorization.isValid(authId, address(s.token), alice, bob, AMOUNT),
            "auth still valid"
        );
    }
}
