// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/**
 * @title ITransferAuthorization
 * @notice Events and errors for the transfer authorization registry.
 *
 * @dev Declared as a concrete contract (no virtual functions) so that:
 *      1. Solidity 0.8.17 allows `emit ITransferAuthorization.EventName()` in any
 *         contract that inherits this type — including `DeployBase` and all test
 *         contracts that extend `BaseTest`.
 *      2. Errors defined here are accessible as `TransferAuthorization.ErrorName`
 *         and as `ITransferAuthorization.ErrorName` from test contracts.
 *
 *      WHY NOT A PURE INTERFACE:
 *        `emit IFace.Event()` qualified-name syntax was added in Solidity 0.8.22.
 *        T-REX v4 is pinned to 0.8.17. Making this a base contract with no storage
 *        and no unimplemented functions (all functions live in the child contract)
 *        lets every contract in the hierarchy share the event/error ABI without
 *        adding any runtime cost.
 *
 *      DESIGN DECISION — on-chain storage vs EIP-712 vouchers (Part C, Q1):
 *        Chosen: on-chain authorization storage. The compliance module resolves
 *        the active authId through `activeAuthIdFor` — an O(1) slot lookup.
 *        Alternative: backend signs off-chain EIP-712 structs. Ruled out because
 *        revocation still needs an on-chain nullifier, `activeAuthIdFor` queries
 *        become impossible, and the signature must be kept secret until submission
 *        (front-run risk on DEX/relayer networks).
 *
 * @dev Authorization struct is also declared here so it is in scope for any contract
 *      that inherits ITransferAuthorization without a separate import.
 */
contract ITransferAuthorization {
    // ─────────────────────────────────────────────────────────────── struct ──

    /**
     * @notice Full authorization record stored on-chain.
     * @param token         ERC-3643 token this authorization covers.
     * @param sender        Address that must initiate the transfer.
     * @param recipient     Address that must receive the tokens.
     * @param amount        Exact token amount; partial use is not supported (R1).
     * @param expiry        Inclusive deadline: block.timestamp <= expiry is valid (R3).
     * @param chainId       Recorded at issue time — blocks cross-chain replay.
     * @param issuedAtEpoch Token epoch at issuance; invalidated by epoch bump (R4).
     * @param consumed      true once used exactly once (R2).
     * @param revoked       true after explicit single revocation (R4).
     */
    struct Authorization {
        address token;
        address sender;
        address recipient;
        uint256 amount;
        uint256 expiry;
        uint256 chainId;
        uint256 issuedAtEpoch;
        bool consumed;
        bool revoked;
    }

    // ─────────────────────────────────────────────────────────────── events ──

    event AuthorizationIssued(
        bytes32 indexed authId,
        address indexed token,
        address indexed sender,
        address recipient,
        uint256 amount,
        uint256 expiry,
        uint256 epoch
    );

    event AuthorizationConsumed(
        bytes32 indexed authId,
        address indexed token,
        address indexed sender,
        address recipient,
        uint256 amount,
        uint256 timestamp
    );

    event AuthorizationRevoked(bytes32 indexed authId, address revokedBy);

    /**
     * @dev Emitted when revokeAllAuthorizations bumps the epoch for a token.
     * @param token     Token whose authorizations were mass-revoked.
     * @param newEpoch  Post-bump epoch value.
     * @param revokedBy Address that triggered the revocation.
     */
    event EpochAdvanced(address indexed token, uint256 newEpoch, address revokedBy);

    // ────────────────────────────────────────────────────── custom errors ──

    error InvalidAuthId();
    error ExpiryNotInFuture(uint256 expiry);
    error AuthIdAlreadyUsed(bytes32 authId);
    error DuplicateActiveAuthorization(bytes32 existingAuthId);
    error AuthorizationNotValid(bytes32 authId);
    error NotAuthorizer(address caller);
    error NotConsumer(address caller);
}
