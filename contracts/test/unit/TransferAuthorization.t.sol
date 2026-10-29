// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "../Base.t.sol";
import "../../src/authorization/TransferAuthorization.sol";

/**
 * @title TransferAuthorizationTest
 * @author Permissioned RWA Platform
 * @notice Requirement R1–R4: ordinary transfers must be backed by a valid, single-use,
 *         backend-issued authorization bound to (token, chain, sender, recipient, amount, epoch).
 * @dev These run through the real token + compliance + module stack; "transfer reverts" means the
 *      token reverts, which is the property that matters in production.
 */
contract TransferAuthorizationTest is BaseTest {
    uint256 internal constant AMOUNT = 100e18;

    // ---------------------------------------------------------------- R1 (happy path)

    function test_AuthorizedTransfer_Succeeds() public {
        bytes32 authId = _issueAuthOneHour(alice, bob, AMOUNT);

        uint256 before = s.token.balanceOf(bob);
        _transfer(alice, bob, AMOUNT);

        assertEq(s.token.balanceOf(bob), before + AMOUNT, "recipient balance");
        assertEq(s.token.balanceOf(alice), INITIAL_SUPPLY - AMOUNT, "sender balance");
    }

    function test_AuthorizedTransfer_ConsumesAuthorization() public {
        bytes32 authId = _issueAuthOneHour(alice, bob, AMOUNT);

        assertFalse(_consumed(authId), "not consumed before");
        assertEq(_activeAuthId(alice, bob, AMOUNT), authId, "active before");

        _transfer(alice, bob, AMOUNT);

        assertTrue(_consumed(authId), "consumed after");
        assertEq(_activeAuthId(alice, bob, AMOUNT), bytes32(0), "active slot cleared");
        assertFalse(s.authorization.isValid(authId, address(s.token), alice, bob, AMOUNT), "no longer valid");
    }

    function test_AuthorizedTransfer_EmitsConsumedEvent() public {
        bytes32 authId = _issueAuthOneHour(alice, bob, AMOUNT);

        vm.expectEmit(true, true, true, true, address(s.authorization));
        emit ITransferAuthorization.AuthorizationConsumed(
            authId, address(s.token), alice, bob, AMOUNT, block.timestamp
        );

        _transfer(alice, bob, AMOUNT);
    }

    // ---------------------------------------------------------------- R2 (no authorization)

    function test_Transfer_WithoutAuthorization_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("Transfer not possible");
        s.token.transfer(bob, AMOUNT);
    }

    function test_Transfer_ExactParametersNotAuthorized_Reverts() public {
        // Authorization exists for a different amount: 100e18, but we transfer 50e18.
        _issueAuthOneHour(alice, bob, AMOUNT);

        vm.prank(alice);
        vm.expectRevert("Transfer not possible");
        s.token.transfer(bob, AMOUNT / 2);
    }

    function test_Transfer_WrongRecipient_Reverts() public {
        _issueAuthOneHour(alice, bob, AMOUNT);

        vm.prank(alice);
        vm.expectRevert("Transfer not possible");
        s.token.transfer(carol, AMOUNT);
    }

    // ---------------------------------------------------------------- R3 (expiry)

    function test_ExpiredAuthorization_Reverts() public {
        uint256 expiry = block.timestamp + 1 hours;
        _issueAuth(alice, bob, AMOUNT, expiry);

        vm.warp(expiry + 1);

        vm.prank(alice);
        vm.expectRevert("Transfer not possible");
        s.token.transfer(bob, AMOUNT);
    }

    /// @dev Documented boundary: `expiry` is INCLUSIVE, so `block.timestamp == expiry` is valid.
    function test_ExpiryBoundary_ValidAtExactExpiry() public {
        uint256 expiry = block.timestamp + 1 hours;
        _issueAuth(alice, bob, AMOUNT, expiry);

        vm.warp(expiry);

        _transfer(alice, bob, AMOUNT);
        assertEq(s.token.balanceOf(bob), AMOUNT);
    }

    function test_ExpiryBoundary_InvalidOneSecondAfter() public {
        uint256 expiry = block.timestamp + 1 hours;
        _issueAuth(alice, bob, AMOUNT, expiry);

        vm.warp(expiry + 1);

        vm.prank(alice);
        vm.expectRevert("Transfer not possible");
        s.token.transfer(bob, AMOUNT);
    }

    function test_IssueReverts_ExpiryNotInFuture() public {
        uint256 expiry = block.timestamp;
        bytes32 authId = s.authorization.computeAuthId(address(s.token), alice, bob, AMOUNT, expiry, 0);

        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(TransferAuthorization.ExpiryNotInFuture.selector, expiry));
        s.authorization.issueAuthorization(authId, address(s.token), alice, bob, AMOUNT, expiry);
    }

    // ---------------------------------------------------------------- R4 (replay)

    function test_ReplayedAuthorization_Reverts() public {
        bytes32 authId = _issueAuthOneHour(alice, bob, AMOUNT);
        _transfer(alice, bob, AMOUNT);
        assertTrue(_consumed(authId));

        // Same authorization cannot back a second transfer.
        vm.prank(alice);
        vm.expectRevert("Transfer not possible");
        s.token.transfer(bob, AMOUNT);
    }

    function test_ReplayedAuthorization_CannotBeConsumedDirectly() public {
        bytes32 authId = _issueAuthOneHour(alice, bob, AMOUNT);
        _transfer(alice, bob, AMOUNT);

        // The module is the only registered consumer; replaying the consume must fail.
        vm.prank(address(s.module));
        vm.expectRevert(abi.encodeWithSelector(TransferAuthorization.AuthorizationNotValid.selector, authId));
        s.authorization.consumeAuthorization(authId, address(s.token), alice, bob, AMOUNT);
    }

    // ---------------------------------------------------------------- revocation (individual + epoch)

    function test_IndividuallyRevokedAuthorization_Reverts() public {
        bytes32 authId = _issueAuthOneHour(alice, bob, AMOUNT);

        vm.prank(backend);
        s.authorization.revokeAuthorization(authId);

        assertTrue(s.authorization.getAuthorization(authId).revoked, "marked revoked");
        assertEq(_activeAuthId(alice, bob, AMOUNT), bytes32(0), "active slot cleared");

        vm.prank(alice);
        vm.expectRevert("Transfer not possible");
        s.token.transfer(bob, AMOUNT);
    }

    function test_EpochRevocation_InvalidatesPriorAuth() public {
        bytes32 authId = _issueAuthOneHour(alice, bob, AMOUNT);

        vm.prank(backend);
        s.authorization.revokeAllAuthorizations(address(s.token));

        assertEq(s.authorization.tokenEpoch(address(s.token)), 1, "epoch bumped");
        assertFalse(s.authorization.isValid(authId, address(s.token), alice, bob, AMOUNT), "invalidated");

        vm.prank(alice);
        vm.expectRevert("Transfer not possible");
        s.token.transfer(bob, AMOUNT);
    }

    function test_EpochRevocation_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(s.authorization));
        emit ITransferAuthorization.EpochAdvanced(address(s.token), 1, backend);

        vm.prank(backend);
        s.authorization.revokeAllAuthorizations(address(s.token));
    }

    function test_NewAuthorizationAfterEpochRevocation_Succeeds() public {
        // An outstanding authorization that will be wiped by the epoch bump.
        _issueAuthOneHour(alice, bob, AMOUNT);

        vm.prank(backend);
        s.authorization.revokeAllAuthorizations(address(s.token));

        // A fresh authorization under the new epoch must be usable (epoch invalidation is not permanent).
        bytes32 fresh = _issueAuth(alice, bob, AMOUNT, block.timestamp + 1 hours, 1);
        assertEq(s.authorization.getAuthorization(fresh).issuedAtEpoch, 1, "issued under new epoch");

        _transfer(alice, bob, AMOUNT);
        assertEq(s.token.balanceOf(bob), AMOUNT);
    }

    function test_NewAuthorizationAfterIndividualRevocation_Succeeds() public {
        bytes32 first = _issueAuthOneHour(alice, bob, AMOUNT);

        vm.prank(backend);
        s.authorization.revokeAuthorization(first);

        _issueAuth(alice, bob, AMOUNT, block.timestamp + 1 hours, 1); // no revert: slot was cleared
        _transfer(alice, bob, AMOUNT);

        assertEq(s.token.balanceOf(bob), AMOUNT);
    }

    // ---------------------------------------------------------------- parameter binding

    function test_RegistryIsValid_RequiresExactParameters() public {
        bytes32 authId = _issueAuthOneHour(alice, bob, AMOUNT);

        assertTrue(s.authorization.isValid(authId, address(s.token), alice, bob, AMOUNT), "exact match");

        assertFalse(s.authorization.isValid(authId, address(0xdead), alice, bob, AMOUNT), "wrong token");
        assertFalse(s.authorization.isValid(authId, address(s.token), bob, bob, AMOUNT), "wrong sender");
        assertFalse(s.authorization.isValid(authId, address(s.token), alice, carol, AMOUNT), "wrong recipient");
        assertFalse(s.authorization.isValid(authId, address(s.token), alice, bob, AMOUNT - 1), "wrong amount");
        assertFalse(s.authorization.isValid(authId, address(s.token), alice, bob, AMOUNT + 1), "wrong amount");
    }

    function test_AuthorizationIsBoundToChainId() public {
        bytes32 authId = _issueAuthOneHour(alice, bob, AMOUNT);
        assertEq(s.authorization.getAuthorization(authId).chainId, block.chainid, "chain id recorded");
    }

    function test_ComputeAuthId_IsDeterministicAndNonceSensitive() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 a = s.authorization.computeAuthId(address(s.token), alice, bob, AMOUNT, expiry, 0);
        bytes32 b = s.authorization.computeAuthId(address(s.token), alice, bob, AMOUNT, expiry, 0);
        bytes32 c = s.authorization.computeAuthId(address(s.token), alice, bob, AMOUNT, expiry, 1);

        assertEq(a, b, "deterministic");
        assertTrue(a != c, "nonce sensitive");
    }

    // ---------------------------------------------------------------- issue-time guards

    function test_IssueReverts_DuplicateActiveAuthorization() public {
        _issueAuthOneHour(alice, bob, AMOUNT);

        uint256 expiry = block.timestamp + 2 hours;
        bytes32 second = s.authorization.computeAuthId(address(s.token), alice, bob, AMOUNT, expiry, 1);

        vm.prank(backend);
        vm.expectRevert(
            abi.encodeWithSelector(
                TransferAuthorization.DuplicateActiveAuthorization.selector, _activeAuthId(alice, bob, AMOUNT)
            )
        );
        s.authorization.issueAuthorization(second, address(s.token), alice, bob, AMOUNT, expiry);
    }

    function test_IssueReverts_ReusedAuthId() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 authId = s.authorization.computeAuthId(address(s.token), alice, bob, AMOUNT, expiry, 0);

        vm.prank(backend);
        s.authorization.issueAuthorization(authId, address(s.token), alice, bob, AMOUNT, expiry);

        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(TransferAuthorization.AuthIdAlreadyUsed.selector, authId));
        s.authorization.issueAuthorization(authId, address(s.token), alice, bob, AMOUNT, expiry);
    }

    function test_IssueReverts_ZeroAuthId() public {
        vm.prank(backend);
        vm.expectRevert(TransferAuthorization.InvalidAuthId.selector);
        s.authorization.issueAuthorization(bytes32(0), address(s.token), alice, bob, AMOUNT, block.timestamp + 1 hours);
    }

    // ---------------------------------------------------------------- access control

    function test_IssueReverts_NonAuthorizer() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 authId = s.authorization.computeAuthId(address(s.token), alice, bob, AMOUNT, expiry, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TransferAuthorization.NotAuthorizer.selector, alice));
        s.authorization.issueAuthorization(authId, address(s.token), alice, bob, AMOUNT, expiry);
    }

    function test_RevokeReverts_NonAuthorizer() public {
        bytes32 authId = _issueAuthOneHour(alice, bob, AMOUNT);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TransferAuthorization.NotAuthorizer.selector, alice));
        s.authorization.revokeAuthorization(authId);
    }

    function test_ConsumeReverts_NonConsumer() public {
        bytes32 authId = _issueAuthOneHour(alice, bob, AMOUNT);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TransferAuthorization.NotConsumer.selector, alice));
        s.authorization.consumeAuthorization(authId, address(s.token), alice, bob, AMOUNT);
    }

    function test_ConsumerAdmin() public {
        address newConsumer = makeAddr("newConsumer");

        assertFalse(s.authorization.isConsumer(newConsumer));
        s.authorization.addConsumer(newConsumer);
        assertTrue(s.authorization.isConsumer(newConsumer));

        s.authorization.removeConsumer(newConsumer);
        assertFalse(s.authorization.isConsumer(newConsumer));
    }

    function test_AuthorizerAdmin() public {
        address newAuthorizer = makeAddr("newAuthorizer");

        assertFalse(s.authorization.isAuthorizer(newAuthorizer));
        s.authorization.addAuthorizer(newAuthorizer);
        assertTrue(s.authorization.isAuthorizer(newAuthorizer));

        s.authorization.removeAuthorizer(newAuthorizer);
        assertFalse(s.authorization.isAuthorizer(newAuthorizer));
    }

    function test_AuthorizerAdmin_RevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        s.authorization.addConsumer(alice);
    }
}
