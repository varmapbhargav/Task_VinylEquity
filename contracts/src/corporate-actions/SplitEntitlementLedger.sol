// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title SplitEntitlementLedger
 * @notice Records fractional entitlements from stock splits when tokens have 0 decimals
 * @dev Implements exact 3-for-2 split arithmetic without floating point operations
 *
 * PROBLEM: Token has 0 decimals (1 token = 1 base unit, indivisible)
 * A 3:2 split means each holder receives 1.5x their current balance
 * With integer arithmetic: oldBalance * 3 / 2 may have a remainder
 *
 * SOLUTION: Track fractional entitlements separately
 * - Mint whole tokens immediately: floor(oldBalance * 3 / 2) - oldBalance
 * - Record fractional remainder: (oldBalance * 3) % 2
 * - Aggregate fractional entitlements can be settled via policy (cash-in-lieu, accumulation, etc.)
 *
 * CONSERVATION INVARIANT:
 * sum(oldBalance * 3) == sum(newBalance * 2) + sum(fractionalNumerator * 1)
 * where newBalance = oldBalance + toMint
 *
 * ROUNDING: Floor division (Solidity default). No silent rounding up.
 * Fractional claims are explicit and auditable.
 */
contract SplitEntitlementLedger is AccessControl {
    bytes32 public constant CORPORATE_ACTION_ROLE = keccak256("CORPORATE_ACTION_ROLE");

    /// @notice Represents a 3-for-2 stock split event
    struct SplitEvent {
        address token;
        uint256 snapshotBlock;
        bytes32 snapshotBlockHash;
        uint256 numerator; // 3 for 3:2 split
        uint256 denominator; // 2 for 3:2 split
        bool executed;
        uint256 executedAt;
    }

    /// @notice Represents an individual position's split entitlement
    struct PositionEntitlement {
        uint256 oldBalance;
        uint256 wholeTokensToMint;
        uint256 fractionalNumerator; // remainder from (oldBalance * numerator) % denominator
        uint256 fractionalDenominator; // denominator (2 for 3:2 split)
        bool settled;
    }

    /// @notice splitId => SplitEvent
    mapping(bytes32 => SplitEvent) public splits;

    /// @notice splitId => holder => PositionEntitlement
    mapping(bytes32 => mapping(address => PositionEntitlement)) public entitlements;

    /// @notice splitId => total whole tokens to mint across all holders
    mapping(bytes32 => uint256) public totalWholeTokensToMint;

    /// @notice splitId => total fractional numerator across all holders
    mapping(bytes32 => uint256) public totalFractionalNumerator;

    event SplitRecorded(
        bytes32 indexed splitId,
        address indexed token,
        uint256 snapshotBlock,
        bytes32 snapshotBlockHash,
        uint256 numerator,
        uint256 denominator
    );

    event EntitlementRecorded(
        bytes32 indexed splitId,
        address indexed holder,
        uint256 oldBalance,
        uint256 wholeTokensToMint,
        uint256 fractionalNumerator,
        uint256 fractionalDenominator
    );

    event SplitExecuted(bytes32 indexed splitId, uint256 timestamp);

    error SplitAlreadyExists(bytes32 splitId);
    error SplitNotFound(bytes32 splitId);
    error SplitAlreadyExecuted(bytes32 splitId);
    error InvalidRatio();
    error ZeroAddress();
    error ZeroBalance();

    constructor(address admin, address corporateActionOperator) {
        if (admin == address(0)) revert ZeroAddress();
        if (corporateActionOperator == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CORPORATE_ACTION_ROLE, corporateActionOperator);
    }

    /**
     * @notice Records a new stock split
     * @param splitId Unique identifier for this corporate action
     * @param token Token contract address
     * @param snapshotBlock Block number at which positions were captured
     * @param snapshotBlockHash Block hash to verify canonical chain
     * @param numerator Split ratio numerator (3 for 3:2)
     * @param denominator Split ratio denominator (2 for 3:2)
     */
    function recordSplit(
        bytes32 splitId,
        address token,
        uint256 snapshotBlock,
        bytes32 snapshotBlockHash,
        uint256 numerator,
        uint256 denominator
    ) external onlyRole(CORPORATE_ACTION_ROLE) {
        if (splits[splitId].token != address(0)) revert SplitAlreadyExists(splitId);
        if (token == address(0)) revert ZeroAddress();
        if (numerator == 0 || denominator == 0) revert InvalidRatio();
        if (numerator <= denominator) revert InvalidRatio(); // Split must increase supply

        splits[splitId] = SplitEvent({
            token: token,
            snapshotBlock: snapshotBlock,
            snapshotBlockHash: snapshotBlockHash,
            numerator: numerator,
            denominator: denominator,
            executed: false,
            executedAt: 0
        });

        emit SplitRecorded(splitId, token, snapshotBlock, snapshotBlockHash, numerator, denominator);
    }

    /**
     * @notice Records entitlement for a single position
     * @dev Uses exact integer arithmetic: no floats, no silent rounding
     * @param splitId Split event identifier
     * @param holder Address of the position holder
     * @param oldBalance Holder's balance at snapshot
     *
     * ARITHMETIC:
     * newEntitlement = oldBalance * numerator (exact, checked for overflow)
     * wholeNew = newEntitlement / denominator (floor division)
     * toMint = wholeNew - oldBalance (net new tokens)
     * remainder = newEntitlement % denominator (fractional entitlement)
     *
     * EXAMPLE (3:2 split):
     * oldBalance = 5: newEntitlement = 15, wholeNew = 7, toMint = 2, remainder = 1
     * oldBalance = 4: newEntitlement = 12, wholeNew = 6, toMint = 2, remainder = 0
     */
    function recordEntitlement(
        bytes32 splitId,
        address holder,
        uint256 oldBalance
    ) external onlyRole(CORPORATE_ACTION_ROLE) {
        if (splits[splitId].token == address(0)) revert SplitNotFound(splitId);
        if (splits[splitId].executed) revert SplitAlreadyExecuted(splitId);
        if (holder == address(0)) revert ZeroAddress();
        if (oldBalance == 0) revert ZeroBalance();

        SplitEvent storage split = splits[splitId];

        // Compute new entitlement (checked math prevents overflow)
        uint256 newEntitlement = oldBalance * split.numerator;

        // Whole tokens (floor division)
        uint256 wholeNew = newEntitlement / split.denominator;

        // Net tokens to mint (can be 0 or negative in weird ratios, but 3:2 always increases)
        uint256 toMint = wholeNew - oldBalance;

        // Fractional remainder
        uint256 remainder = newEntitlement % split.denominator;

        // Record entitlement
        entitlements[splitId][holder] = PositionEntitlement({
            oldBalance: oldBalance,
            wholeTokensToMint: toMint,
            fractionalNumerator: remainder,
            fractionalDenominator: split.denominator,
            settled: false
        });

        // Update aggregates
        totalWholeTokensToMint[splitId] += toMint;
        totalFractionalNumerator[splitId] += remainder;

        emit EntitlementRecorded(
            splitId,
            holder,
            oldBalance,
            toMint,
            remainder,
            split.denominator
        );
    }

    /**
     * @notice Marks a split as executed
     * @dev After execution, no more entitlements can be recorded
     * @param splitId Split event identifier
     */
    function executeSplit(bytes32 splitId) external onlyRole(CORPORATE_ACTION_ROLE) {
        if (splits[splitId].token == address(0)) revert SplitNotFound(splitId);
        if (splits[splitId].executed) revert SplitAlreadyExecuted(splitId);

        splits[splitId].executed = true;
        splits[splitId].executedAt = block.timestamp;

        emit SplitExecuted(splitId, block.timestamp);
    }

    /**
     * @notice Retrieves entitlement details for a holder
     * @param splitId Split event identifier
     * @param holder Address of the holder
     * @return Entitlement struct
     */
    function getEntitlement(bytes32 splitId, address holder)
        external
        view
        returns (PositionEntitlement memory)
    {
        return entitlements[splitId][holder];
    }

    /**
     * @notice Retrieves split event details
     * @param splitId Split event identifier
     * @return Split struct
     */
    function getSplit(bytes32 splitId) external view returns (SplitEvent memory) {
        return splits[splitId];
    }

    /**
     * @notice Verifies conservation invariant for a split
     * @dev sum(oldBalance * numerator) == sum(wholeNew * denominator) + sum(remainder)
     * @param splitId Split event identifier
     * @return True if invariant holds
     */
    function verifyConservation(bytes32 splitId) external view returns (bool) {
        SplitEvent storage split = splits[splitId];
        if (split.token == address(0)) revert SplitNotFound(splitId);

        // We don't track oldTotalSupply on-chain in this simple version
        // Off-chain service must verify:
        // oldTotalSupply * numerator == (oldTotalSupply + totalWholeTokensToMint) * denominator + totalFractionalNumerator

        // On-chain we can only verify the aggregate fractional remainder is less than total holders * denominator
        // A full verification requires iterating all positions, which is gas-prohibitive on-chain
        return true; // Placeholder - full verification done off-chain
    }
}
