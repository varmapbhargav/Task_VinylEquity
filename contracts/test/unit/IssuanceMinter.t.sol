// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "../Base.t.sol";
import "../../src/authorization/IssuanceMinter.sol";

/**
 * @title IssuanceMinterTest
 * @author Permissioned RWA Platform
 * @notice Requirement R6: Idempotent issuance — duplicate issuanceId reverts immediately,
 *         preventing accidental double-minting even under RPC timeout / crash / reorg conditions.
 * @dev The idempotency guarantee lives on-chain in the `usedIssuanceIds` mapping.
 */
contract IssuanceMinterTest is BaseTest {
    uint256 internal constant MINT_AMOUNT = 50_000e18;
    bytes32 internal constant ISSUANCE_ID_1 = keccak256("issuance-001");
    bytes32 internal constant ISSUANCE_ID_2 = keccak256("issuance-002");

    // ---------------------------------------------------------------- R6 (happy path)

    function test_MintWithIssuanceId_Succeeds() public {
        uint256 before = s.token.balanceOf(bob);

        s.minter.mintWithIssuanceId(bob, MINT_AMOUNT, ISSUANCE_ID_1);

        assertEq(s.token.balanceOf(bob), before + MINT_AMOUNT, "minted correctly");
        assertTrue(s.minter.usedIssuanceIds(ISSUANCE_ID_1), "issuance marked used");
    }

    function test_MintWithIssuanceId_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(s.minter));
        emit IssuanceMinter.IssuanceMinted(ISSUANCE_ID_1, bob, MINT_AMOUNT);

        s.minter.mintWithIssuanceId(bob, MINT_AMOUNT, ISSUANCE_ID_1);
    }

    function test_MultipleDifferentIssuances_Succeed() public {
        s.minter.mintWithIssuanceId(bob, MINT_AMOUNT, ISSUANCE_ID_1);
        s.minter.mintWithIssuanceId(carol, MINT_AMOUNT * 2, ISSUANCE_ID_2);

        assertEq(s.token.balanceOf(bob), MINT_AMOUNT, "bob balance");
        assertEq(s.token.balanceOf(carol), MINT_AMOUNT * 2, "carol balance");
        assertTrue(s.minter.usedIssuanceIds(ISSUANCE_ID_1), "ID 1 used");
        assertTrue(s.minter.usedIssuanceIds(ISSUANCE_ID_2), "ID 2 used");
    }

    // ---------------------------------------------------------------- R6 (duplicate issuance ID)

    /// @notice CORE REQUIREMENT: Duplicate issuanceId reverts immediately, preventing double-mint.
    function test_DuplicateIssuanceId_Reverts() public {
        s.minter.mintWithIssuanceId(bob, MINT_AMOUNT, ISSUANCE_ID_1);

        // Second mint with same issuance ID reverts regardless of recipient or amount
        vm.expectRevert(abi.encodeWithSelector(IssuanceMinter.IssuanceAlreadyMinted.selector, ISSUANCE_ID_1));
        s.minter.mintWithIssuanceId(bob, MINT_AMOUNT, ISSUANCE_ID_1);
    }

    /// @notice Even with different recipient, duplicate ID still reverts.
    function test_DuplicateIssuanceId_DifferentRecipient_Reverts() public {
        s.minter.mintWithIssuanceId(bob, MINT_AMOUNT, ISSUANCE_ID_1);

        vm.expectRevert(abi.encodeWithSelector(IssuanceMinter.IssuanceAlreadyMinted.selector, ISSUANCE_ID_1));
        s.minter.mintWithIssuanceId(carol, MINT_AMOUNT, ISSUANCE_ID_1);
    }

    /// @notice Even with different amount, duplicate ID still reverts.
    function test_DuplicateIssuanceId_DifferentAmount_Reverts() public {
        s.minter.mintWithIssuanceId(bob, MINT_AMOUNT, ISSUANCE_ID_1);

        vm.expectRevert(abi.encodeWithSelector(IssuanceMinter.IssuanceAlreadyMinted.selector, ISSUANCE_ID_1));
        s.minter.mintWithIssuanceId(bob, MINT_AMOUNT * 10, ISSUANCE_ID_1);
    }

    // ---------------------------------------------------------------- idempotency guarantee survives revert

    /// @notice CRITICAL: issuanceId is marked BEFORE mint() is called. If mint() reverts
    ///         (e.g., token paused, recipient not verified, compliance blocked), the ID
    ///         remains consumed. This prevents silent retry loops and forces the backend
    ///         to investigate and open a new issuanceId if needed.
    function test_IdempotencyMarkPersists_EvenIfMintReverts() public {
        // Pause the token so mint() will revert
        s.token.pause();

        // Attempt to mint — will fail because token is paused
        vm.expectRevert("Pausable: paused");
        s.minter.mintWithIssuanceId(bob, MINT_AMOUNT, ISSUANCE_ID_1);

        // The issuanceId is marked as used despite the revert
        assertTrue(s.minter.usedIssuanceIds(ISSUANCE_ID_1), "ID marked used even after revert");

        // Unpause and try again with the SAME issuanceId — must still revert
        s.token.unpause();
        vm.expectRevert(abi.encodeWithSelector(IssuanceMinter.IssuanceAlreadyMinted.selector, ISSUANCE_ID_1));
        s.minter.mintWithIssuanceId(bob, MINT_AMOUNT, ISSUANCE_ID_1);
    }

    /// @notice If recipient is not registered, mint reverts, but ID is still consumed.
    function test_IdempotencyMarkPersists_RecipientNotRegistered() public {
        address unregistered = makeAddr("unregistered");

        // Mint to unregistered address — will fail compliance
        vm.expectRevert("Transfer not possible");
        s.minter.mintWithIssuanceId(unregistered, MINT_AMOUNT, ISSUANCE_ID_1);

        // The issuanceId is marked as used
        assertTrue(s.minter.usedIssuanceIds(ISSUANCE_ID_1), "ID marked used even for failed mint");

        // Register the address and try again — must still revert with duplicate ID
        _registerInvestor(s, unregistered, COUNTRY_US);
        vm.expectRevert(abi.encodeWithSelector(IssuanceMinter.IssuanceAlreadyMinted.selector, ISSUANCE_ID_1));
        s.minter.mintWithIssuanceId(unregistered, MINT_AMOUNT, ISSUANCE_ID_1);
    }

    // ---------------------------------------------------------------- input validation

    function test_MintReverts_ZeroRecipient() public {
        vm.expectRevert("IssuanceMinter: zero recipient");
        s.minter.mintWithIssuanceId(address(0), MINT_AMOUNT, ISSUANCE_ID_1);
    }

    function test_MintReverts_ZeroAmount() public {
        vm.expectRevert("IssuanceMinter: zero amount");
        s.minter.mintWithIssuanceId(bob, 0, ISSUANCE_ID_1);
    }

    // ---------------------------------------------------------------- access control

    /// @notice Only the minter's owner can mint (backend hot key in production).
    function test_MintReverts_NonOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        s.minter.mintWithIssuanceId(bob, MINT_AMOUNT, ISSUANCE_ID_1);
    }

    // ---------------------------------------------------------------- minter role in token

    /// @notice The minter must be a token agent; if not, mint() will revert.
    function test_MintReverts_MinterNotAgent() public {
        // Deploy a fresh minter NOT added as token agent
        IssuanceMinter freshMinter = new IssuanceMinter(address(s.token));

        vm.prank(address(this)); // owner of freshMinter
        vm.expectRevert("Role: Sender is not a token agent");
        freshMinter.mintWithIssuanceId(bob, MINT_AMOUNT, ISSUANCE_ID_1);
    }

    // ---------------------------------------------------------------- fuzz

    /// @notice Fuzz test: any issuanceId can be used exactly once, never twice.
    function testFuzz_DuplicateIssuanceId_AlwaysReverts(bytes32 issuanceId, address recipient, uint256 amount) public {
        vm.assume(recipient != address(0));
        vm.assume(amount > 0 && amount <= type(uint96).max); // reasonable bounds
        vm.assume(s.ir.isVerified(recipient)); // must be registered

        // First mint succeeds
        s.minter.mintWithIssuanceId(recipient, amount, issuanceId);
        assertTrue(s.minter.usedIssuanceIds(issuanceId), "ID used");

        // Second mint with same ID reverts
        vm.expectRevert(abi.encodeWithSelector(IssuanceMinter.IssuanceAlreadyMinted.selector, issuanceId));
        s.minter.mintWithIssuanceId(recipient, amount, issuanceId);
    }
}
