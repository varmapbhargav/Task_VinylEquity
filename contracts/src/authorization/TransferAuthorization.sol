// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/ITransferAuthorization.sol";

/**
 * @title TransferAuthorization
 * @notice Backend-authoritative transfer-permission registry for ERC-3643 tokens.
 *
 * ─── DESIGN RATIONALE (Part C, Q1) ──────────────────────────────────────────
 *
 * PLACEMENT — compliance module, not token extension, not adapter:
 *   The `canTransfer` / `moduleCheck` hook is the designed extension point for
 *   per-transfer business rules in T-REX. The token itself is never modified.
 *   Agent operations (mint, burn, forcedTransfer, freeze, wallet recovery) use
 *   code paths that bypass `canTransfer`, satisfying R5 naturally.
 *   Exception: `mint` calls `canTransfer(address(0), to, amount)` — the module
 *   returns true for `from == address(0)` so mints are never blocked.
 *
 * ACTIVE-SLOT MAPPING:
 *   _activeAuthId[token][from][to][amount] → authId. Only one active auth per
 *   transfer tuple is allowed. Cleared on consumption or individual revocation.
 *   Epoch revocation does NOT clear slots; the epoch check in isValid / consume
 *   makes stale slots harmless.
 *
 * ROLE MODEL:
 *   owner       — Ownable; manages authorizers and consumers.
 *   authorizer  — backend signer; issues and revokes authorizations.
 *   consumer    — the compliance module; the only caller of consumeAuthorization.
 * ─────────────────────────────────────────────────────────────────────────────
 */
contract TransferAuthorization is ITransferAuthorization, Ownable {
    // ─────────────────────────────────────────────────────────── storage ──

    mapping(bytes32 => Authorization) private _authorizations;

    /// active authId per (token, sender, recipient, amount) slot
    mapping(address => mapping(address => mapping(address => mapping(uint256 => bytes32)))) private _activeAuthId;

    /// per-token epoch for O(1) mass invalidation
    mapping(address => uint256) private _tokenEpoch;

    mapping(address => bool) private _authorizers;
    mapping(address => bool) private _consumers;

    // ─────────────────────────────────────────────────────── constructor ──

    constructor(address admin, address backendSigner) {
        require(admin != address(0), "TA: zero admin");
        require(backendSigner != address(0), "TA: zero signer");
        _transferOwnership(admin);
        _authorizers[backendSigner] = true;
    }

    // ─────────────────────────────────────────────────── modifiers ──

    modifier onlyAuthorizer() {
        if (!_authorizers[msg.sender]) revert NotAuthorizer(msg.sender);
        _;
    }

    modifier onlyConsumer() {
        if (!_consumers[msg.sender]) revert NotConsumer(msg.sender);
        _;
    }

    // ─────────────────────────────────────────────── issue ──

    /**
     * @notice Issue a new authorization for a specific transfer.
     * @dev Validates: authId non-zero, not previously stored (R2), expiry future (R3),
     *      no active duplicate for the tuple (one slot per transfer tuple).
     *      Records the current epoch so epoch-bumps invalidate it (R4).
     */
    function issueAuthorization(
        bytes32 authId,
        address token,
        address sender,
        address recipient,
        uint256 amount,
        uint256 expiry
    ) external onlyAuthorizer {
        if (authId == bytes32(0)) revert InvalidAuthId();
        if (expiry <= block.timestamp) revert ExpiryNotInFuture(expiry);
        if (_authorizations[authId].token != address(0)) revert AuthIdAlreadyUsed(authId);

        bytes32 existing = _activeAuthId[token][sender][recipient][amount];
        if (existing != bytes32(0) && _isSlotActive(existing, token)) {
            revert DuplicateActiveAuthorization(existing);
        }

        uint256 epoch = _tokenEpoch[token];

        _authorizations[authId] = Authorization({
            token: token,
            sender: sender,
            recipient: recipient,
            amount: amount,
            expiry: expiry,
            chainId: block.chainid,
            issuedAtEpoch: epoch,
            consumed: false,
            revoked: false
        });

        _activeAuthId[token][sender][recipient][amount] = authId;

        emit AuthorizationIssued(authId, token, sender, recipient, amount, expiry, epoch);
    }

    /**
     * @notice Atomically consume an authorization during a transfer.
     * @dev Only callable by a registered consumer (compliance module). Validates
     *      every field; marks consumed (R2); clears the active slot.
     */
    function consumeAuthorization(
        bytes32 authId,
        address token,
        address sender,
        address recipient,
        uint256 amount
    ) external onlyConsumer {
        Authorization storage auth = _authorizations[authId];

        if (
            auth.token != token
                || auth.sender != sender
                || auth.recipient != recipient
                || auth.amount != amount
                || auth.consumed
                || auth.revoked
                || block.timestamp > auth.expiry
                || auth.issuedAtEpoch < _tokenEpoch[token]
        ) {
            revert AuthorizationNotValid(authId);
        }

        auth.consumed = true;
        delete _activeAuthId[token][sender][recipient][amount];

        emit AuthorizationConsumed(authId, token, sender, recipient, amount, block.timestamp);
    }

    /**
     * @notice Revoke a single authorization (R4).
     * @dev Marks revoked and clears the active slot so a fresh auth can be issued.
     */
    function revokeAuthorization(bytes32 authId) external onlyAuthorizer {
        Authorization storage auth = _authorizations[authId];
        require(auth.token != address(0), "TA: not found");
        require(!auth.consumed, "TA: already consumed");
        require(!auth.revoked, "TA: already revoked");

        auth.revoked = true;
        delete _activeAuthId[auth.token][auth.sender][auth.recipient][auth.amount];

        emit AuthorizationRevoked(authId, msg.sender);
    }

    /**
     * @notice Revoke every outstanding authorization for `token` via epoch bump (R4).
     * @dev O(1) regardless of outstanding count. Slots are NOT cleared; the epoch
     *      check makes all pre-bump auths invalid atomically.
     */
    function revokeAllAuthorizations(address token) external onlyAuthorizer {
        require(token != address(0), "TA: zero token");
        uint256 newEpoch = _tokenEpoch[token] + 1;
        _tokenEpoch[token] = newEpoch;
        emit EpochAdvanced(token, newEpoch, msg.sender);
    }

    // ─────────────────────────────────────────────────────── view functions ──

    /**
     * @notice Non-consuming validity check. Returns false on any invalid condition.
     */
    function isValid(
        bytes32 authId,
        address token,
        address sender,
        address recipient,
        uint256 amount
    ) external view returns (bool) {
        Authorization storage auth = _authorizations[authId];
        if (auth.token == address(0)) return false;
        if (auth.token != token) return false;
        if (auth.sender != sender) return false;
        if (auth.recipient != recipient) return false;
        if (auth.amount != amount) return false;
        if (auth.consumed) return false;
        if (auth.revoked) return false;
        if (block.timestamp > auth.expiry) return false;
        if (auth.issuedAtEpoch < _tokenEpoch[token]) return false;
        return true;
    }

    /**
     * @notice Returns the active authId for a transfer tuple, or bytes32(0).
     * @dev Returns 0 if the slot points to an epoch-invalidated auth.
     */
    function activeAuthIdFor(
        address token,
        address sender,
        address recipient,
        uint256 amount
    ) external view returns (bytes32) {
        bytes32 id = _activeAuthId[token][sender][recipient][amount];
        if (id == bytes32(0)) return bytes32(0);
        if (!_isSlotActive(id, token)) return bytes32(0);
        return id;
    }

    function getAuthorization(bytes32 authId) external view returns (Authorization memory) {
        return _authorizations[authId];
    }

    /**
     * @notice Deterministic authId computation. Include `nonce` to issue multiple auths
     *         for the same tuple without hash collision.
     */
    function computeAuthId(
        address token,
        address sender,
        address recipient,
        uint256 amount,
        uint256 expiry,
        uint256 nonce
    ) external view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, token, sender, recipient, amount, expiry, nonce));
    }

    function tokenEpoch(address token) external view returns (uint256) {
        return _tokenEpoch[token];
    }

    // ─────────────────────────────────────────────── role management ──

    function isAuthorizer(address account) external view returns (bool) {
        return _authorizers[account];
    }

    function isConsumer(address account) external view returns (bool) {
        return _consumers[account];
    }

    function addAuthorizer(address account) external onlyOwner {
        require(account != address(0), "TA: zero address");
        _authorizers[account] = true;
    }

    function removeAuthorizer(address account) external onlyOwner {
        _authorizers[account] = false;
    }

    function addConsumer(address account) external onlyOwner {
        require(account != address(0), "TA: zero address");
        _consumers[account] = true;
    }

    function removeConsumer(address account) external onlyOwner {
        _consumers[account] = false;
    }

    // ─────────────────────────────────────────────────── internal helpers ──

    /**
     * @dev Returns true if the auth stored at authId is still slot-active.
     *      Expiry is NOT checked — an expired but unconsumed auth blocks a new issuance
     *      (backend must explicitly revoke to free the slot).
     */
    function _isSlotActive(bytes32 authId, address token) private view returns (bool) {
        Authorization storage auth = _authorizations[authId];
        if (auth.consumed) return false;
        if (auth.revoked) return false;
        if (auth.issuedAtEpoch < _tokenEpoch[token]) return false;
        return true;
    }
}
