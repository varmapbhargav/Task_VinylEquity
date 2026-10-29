// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../../src/corporate-actions/SplitEntitlementLedger.sol";

/**
 * @title SplitEntitlementLedgerTest
 * @author Permissioned RWA Platform
 * @notice Tests for 3:2 stock split with 0-decimal tokens, fractional tracking, and conservation.
 * @dev Requirement R7: Handle stock splits with exact floor division, no silent rounding,
 *      explicit fractional entitlement tracking.
 */
contract SplitEntitlementLedgerTest is Test {
    SplitEntitlementLedger internal ledger;

    address internal admin;
    address internal operator;
    address internal token;
    address internal holder1;
    address internal holder2;
    address internal holder3;

    bytes32 internal constant SPLIT_ID = keccak256("split-2024-q1");
    uint256 internal constant SNAPSHOT_BLOCK = 1000;
    bytes32 internal constant SNAPSHOT_HASH = bytes32(uint256(0xabcd));

    function setUp() public {
        admin = address(this);
        operator = makeAddr("operator");
        token = makeAddr("token");
        holder1 = makeAddr("holder1");
        holder2 = makeAddr("holder2");
        holder3 = makeAddr("holder3");

        ledger = new SplitEntitlementLedger(admin, operator);
    }

    // ---------------------------------------------------------------- split recording

    function test_RecordSplit_3For2_Succeeds() public {
        vm.prank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        SplitEntitlementLedger.SplitEvent memory split = ledger.getSplit(SPLIT_ID);
        assertEq(split.token, token, "token");
        assertEq(split.numerator, 3, "numerator");
        assertEq(split.denominator, 2, "denominator");
        assertEq(split.snapshotBlock, SNAPSHOT_BLOCK, "snapshot block");
        assertEq(split.snapshotBlockHash, SNAPSHOT_HASH, "snapshot hash");
        assertFalse(split.executed, "not executed");
    }

    function test_RecordSplit_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit SplitEntitlementLedger.SplitRecorded(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        vm.prank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);
    }

    function test_RecordSplit_RevertsDuplicate() public {
        vm.startPrank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        vm.expectRevert(abi.encodeWithSelector(SplitEntitlementLedger.SplitAlreadyExists.selector, SPLIT_ID));
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);
        vm.stopPrank();
    }

    function test_RecordSplit_RevertsInvalidRatio_ZeroNumerator() public {
        vm.prank(operator);
        vm.expectRevert(SplitEntitlementLedger.InvalidRatio.selector);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 0, 2);
    }

    function test_RecordSplit_RevertsInvalidRatio_ZeroDenominator() public {
        vm.prank(operator);
        vm.expectRevert(SplitEntitlementLedger.InvalidRatio.selector);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 0);
    }

    function test_RecordSplit_RevertsInvalidRatio_NoSupplyIncrease() public {
        vm.prank(operator);
        vm.expectRevert(SplitEntitlementLedger.InvalidRatio.selector);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 2, 3); // 2:3 is reverse split
    }

    function test_RecordSplit_RevertsInvalidRatio_Equal() public {
        vm.prank(operator);
        vm.expectRevert(SplitEntitlementLedger.InvalidRatio.selector);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 2, 2); // 1:1 no-op
    }

    function test_RecordSplit_RevertsZeroToken() public {
        vm.prank(operator);
        vm.expectRevert(SplitEntitlementLedger.ZeroAddress.selector);
        ledger.recordSplit(SPLIT_ID, address(0), SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);
    }

    // ---------------------------------------------------------------- entitlement recording

    function test_RecordEntitlement_OddBalance_TracksRemainder() public {
        vm.prank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        // oldBalance = 5: newEntitlement = 5 * 3 = 15
        // wholeNew = 15 / 2 = 7, toMint = 7 - 5 = 2, remainder = 15 % 2 = 1
        vm.prank(operator);
        ledger.recordEntitlement(SPLIT_ID, holder1, 5);

        SplitEntitlementLedger.PositionEntitlement memory ent = ledger.getEntitlement(SPLIT_ID, holder1);
        assertEq(ent.oldBalance, 5, "old balance");
        assertEq(ent.wholeTokensToMint, 2, "whole tokens");
        assertEq(ent.fractionalNumerator, 1, "fractional numerator (1/2)");
        assertEq(ent.fractionalDenominator, 2, "fractional denominator");
        assertFalse(ent.settled, "not settled");
    }

    function test_RecordEntitlement_EvenBalance_NoRemainder() public {
        vm.prank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        // oldBalance = 4: newEntitlement = 4 * 3 = 12
        // wholeNew = 12 / 2 = 6, toMint = 6 - 4 = 2, remainder = 12 % 2 = 0
        vm.prank(operator);
        ledger.recordEntitlement(SPLIT_ID, holder1, 4);

        SplitEntitlementLedger.PositionEntitlement memory ent = ledger.getEntitlement(SPLIT_ID, holder1);
        assertEq(ent.oldBalance, 4, "old balance");
        assertEq(ent.wholeTokensToMint, 2, "whole tokens");
        assertEq(ent.fractionalNumerator, 0, "no fractional");
        assertEq(ent.fractionalDenominator, 2, "denominator");
    }

    function test_RecordEntitlement_MultipleHolders_AggregatesCorrectly() public {
        vm.startPrank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        // holder1: oldBalance = 5 → toMint = 2, remainder = 1
        ledger.recordEntitlement(SPLIT_ID, holder1, 5);

        // holder2: oldBalance = 4 → toMint = 2, remainder = 0
        ledger.recordEntitlement(SPLIT_ID, holder2, 4);

        // holder3: oldBalance = 7 → newEntitlement = 21, wholeNew = 10, toMint = 3, remainder = 1
        ledger.recordEntitlement(SPLIT_ID, holder3, 7);
        vm.stopPrank();

        assertEq(ledger.totalWholeTokensToMint(SPLIT_ID), 2 + 2 + 3, "total whole tokens");
        assertEq(ledger.totalFractionalNumerator(SPLIT_ID), 1 + 0 + 1, "total fractional");
    }

    function test_RecordEntitlement_EmitsEvent() public {
        vm.startPrank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        vm.expectEmit(true, true, true, true);
        emit SplitEntitlementLedger.EntitlementRecorded(SPLIT_ID, holder1, 5, 2, 1, 2);

        ledger.recordEntitlement(SPLIT_ID, holder1, 5);
        vm.stopPrank();
    }

    function test_RecordEntitlement_RevertsSplitNotFound() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SplitEntitlementLedger.SplitNotFound.selector, SPLIT_ID));
        ledger.recordEntitlement(SPLIT_ID, holder1, 100);
    }

    function test_RecordEntitlement_RevertsSplitAlreadyExecuted() public {
        vm.startPrank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);
        ledger.executeSplit(SPLIT_ID);

        vm.expectRevert(abi.encodeWithSelector(SplitEntitlementLedger.SplitAlreadyExecuted.selector, SPLIT_ID));
        ledger.recordEntitlement(SPLIT_ID, holder1, 100);
        vm.stopPrank();
    }

    function test_RecordEntitlement_RevertsZeroAddress() public {
        vm.startPrank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        vm.expectRevert(SplitEntitlementLedger.ZeroAddress.selector);
        ledger.recordEntitlement(SPLIT_ID, address(0), 100);
        vm.stopPrank();
    }

    function test_RecordEntitlement_RevertsZeroBalance() public {
        vm.startPrank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        vm.expectRevert(SplitEntitlementLedger.ZeroBalance.selector);
        ledger.recordEntitlement(SPLIT_ID, holder1, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- split execution

    function test_ExecuteSplit_MarksSplitExecuted() public {
        vm.startPrank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        ledger.executeSplit(SPLIT_ID);
        vm.stopPrank();

        SplitEntitlementLedger.SplitEvent memory split = ledger.getSplit(SPLIT_ID);
        assertTrue(split.executed, "executed");
        assertEq(split.executedAt, block.timestamp, "executed at");
    }

    function test_ExecuteSplit_EmitsEvent() public {
        vm.startPrank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        vm.expectEmit(true, true, true, true);
        emit SplitEntitlementLedger.SplitExecuted(SPLIT_ID, block.timestamp);

        ledger.executeSplit(SPLIT_ID);
        vm.stopPrank();
    }

    function test_ExecuteSplit_RevertsSplitNotFound() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SplitEntitlementLedger.SplitNotFound.selector, SPLIT_ID));
        ledger.executeSplit(SPLIT_ID);
    }

    function test_ExecuteSplit_RevertsIfAlreadyExecuted() public {
        vm.startPrank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);
        ledger.executeSplit(SPLIT_ID);

        vm.expectRevert(abi.encodeWithSelector(SplitEntitlementLedger.SplitAlreadyExecuted.selector, SPLIT_ID));
        ledger.executeSplit(SPLIT_ID);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- conservation property

    /// @notice PROPERTY: sum(oldBalance * 3) == sum(newBalance * 2) + sum(remainder)
    /// @dev For a 3:2 split, the conservation invariant holds for all inputs.
    function test_Conservation_Holds() public {
        vm.startPrank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        uint256[] memory balances = new uint256[](5);
        balances[0] = 5;  // odd
        balances[1] = 4;  // even
        balances[2] = 7;  // odd
        balances[3] = 10; // even
        balances[4] = 1;  // odd

        address[] memory holders = new address[](5);
        holders[0] = holder1;
        holders[1] = holder2;
        holders[2] = holder3;
        holders[3] = makeAddr("holder4");
        holders[4] = makeAddr("holder5");

        uint256 oldTotalSupply = 0;
        for (uint256 i = 0; i < balances.length; i++) {
            oldTotalSupply += balances[i];
            ledger.recordEntitlement(SPLIT_ID, holders[i], balances[i]);
        }
        vm.stopPrank();

        uint256 totalWhole = ledger.totalWholeTokensToMint(SPLIT_ID);
        uint256 totalFractional = ledger.totalFractionalNumerator(SPLIT_ID);
        uint256 newTotalSupply = oldTotalSupply + totalWhole;

        // Conservation: oldTotalSupply * 3 == newTotalSupply * 2 + totalFractional
        assertEq(oldTotalSupply * 3, newTotalSupply * 2 + totalFractional, "conservation");
    }

    /// @notice Fuzz test: conservation holds for arbitrary balances.
    function testFuzz_Conservation(uint256[10] memory balances) public {
        vm.startPrank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        uint256 oldTotalSupply = 0;
        for (uint256 i = 0; i < balances.length; i++) {
            // Bound to reasonable range to prevent overflow in multiplication
            balances[i] = bound(balances[i], 1, type(uint96).max);
            oldTotalSupply += balances[i];

            address holder = address(uint160(i + 1));
            ledger.recordEntitlement(SPLIT_ID, holder, balances[i]);
        }
        vm.stopPrank();

        uint256 totalWhole = ledger.totalWholeTokensToMint(SPLIT_ID);
        uint256 totalFractional = ledger.totalFractionalNumerator(SPLIT_ID);
        uint256 newTotalSupply = oldTotalSupply + totalWhole;

        // Conservation: oldTotalSupply * 3 == newTotalSupply * 2 + totalFractional
        assertEq(oldTotalSupply * 3, newTotalSupply * 2 + totalFractional, "fuzz conservation");
    }

    // ---------------------------------------------------------------- access control

    function test_RecordSplit_RevertsForNonOperator() public {
        vm.prank(holder1);
        vm.expectRevert(); // AccessControl revert
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);
    }

    function test_RecordEntitlement_RevertsForNonOperator() public {
        vm.prank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        vm.prank(holder1);
        vm.expectRevert(); // AccessControl revert
        ledger.recordEntitlement(SPLIT_ID, holder1, 100);
    }

    function test_ExecuteSplit_RevertsForNonOperator() public {
        vm.prank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        vm.prank(holder1);
        vm.expectRevert(); // AccessControl revert
        ledger.executeSplit(SPLIT_ID);
    }

    // ---------------------------------------------------------------- edge cases

    function test_SingleTokenBalance_1() public {
        vm.startPrank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        // oldBalance = 1: newEntitlement = 3, wholeNew = 1, toMint = 0, remainder = 1
        ledger.recordEntitlement(SPLIT_ID, holder1, 1);
        vm.stopPrank();

        SplitEntitlementLedger.PositionEntitlement memory ent = ledger.getEntitlement(SPLIT_ID, holder1);
        assertEq(ent.wholeTokensToMint, 0, "no whole tokens to mint");
        assertEq(ent.fractionalNumerator, 1, "1/2 fractional");
    }

    function test_LargeBalance_NoOverflow() public {
        vm.startPrank(operator);
        ledger.recordSplit(SPLIT_ID, token, SNAPSHOT_BLOCK, SNAPSHOT_HASH, 3, 2);

        // Use a large but safe balance: 2^96 - 1 (common token supply cap)
        uint256 largeBalance = type(uint96).max;
        address largeHolder = makeAddr("largeHolder");

        ledger.recordEntitlement(SPLIT_ID, largeHolder, largeBalance);
        vm.stopPrank();

        SplitEntitlementLedger.PositionEntitlement memory ent = ledger.getEntitlement(SPLIT_ID, largeHolder);
        assertGt(ent.wholeTokensToMint, 0, "large balance computes correctly");
    }
}
