// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "erc3643/token/IToken.sol";

/**
 * @title IssuanceMinter
 * @notice Idempotent mint wrapper for ERC-3643 tokens (R6).
 *
 * ─── DESIGN RATIONALE (Part C — R6) ─────────────────────────────────────────
 *
 * WHERE THE GUARANTEE LIVES: On-chain in this contract.
 *
 *   Option A (chosen): An on-chain `usedIssuanceIds` mapping prevents the same
 *   `issuanceId` from ever minting twice, even if the backend submits the
 *   transaction multiple times due to RPC timeout, crash, or reorg uncertainty.
 *
 *   Option B: Backend-only idempotency — the backend tracks submitted tx hashes
 *   and never resubmits a confirmed issuanceId. REJECTED because:
 *     - Does not survive backend data loss.
 *     - RPC ambiguity (timeout without receipt) makes it impossible to know
 *       whether a tx was included. The backend would have to choose between
 *       "risk double-mint" or "leave tokens unissued". On-chain idempotency
 *       eliminates the dilemma: retry is always safe.
 *
 * WHO HOLDS MINT AUTHORITY:
 *   This contract is the only address with the agent role for minting. The
 *   deployer adds this contract as a token agent. No other address should have
 *   the agent role for minting in production.
 *
 *   In the Foundry test fixture the test contract (owner) also holds the agent
 *   role (for forced-transfer and freeze tests), but minting always goes through
 *   `IssuanceMinter.mintWithIssuanceId` — the fixture's seed mint in `setUp`
 *   also uses this contract.
 *
 * ATOMICITY:
 *   `usedIssuanceIds[issuanceId] = true` is written BEFORE `token.mint()`.
 *   If `mint()` reverts (paused, identity not registered, compliance), the
 *   issuanceId is marked used, preventing a silent retry. The backend must
 *   investigate and, if appropriate, open a new issuanceId.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 *
 * ROLE MODEL:
 *   The contract inherits `Ownable`. The owner can add/remove authorised issuers.
 *   At deploy time the deployer (owner) is the only issuer; `DeployBase` does not
 *   grant additional roles. Tests call `mintWithIssuanceId` directly as owner.
 *
 * SINGLE-TOKEN SCOPE:
 *   One `IssuanceMinter` per token. The token address is immutable.
 */
contract IssuanceMinter is Ownable {
    // ─────────────────────────────────────────────────────────── storage ──

    /// @notice The ERC-3643 token this minter serves.
    IToken public immutable token;

    /// @notice Records every issuanceId that has been presented to `mintWithIssuanceId`.
    /// @dev Marked `true` BEFORE `token.mint()` is called, regardless of whether
    ///      mint succeeds or reverts.
    mapping(bytes32 => bool) public usedIssuanceIds;

    // ─────────────────────────────────────────────────────────── events ──

    /// @notice Emitted when tokens are successfully minted for an issuanceId.
    event IssuanceMinted(bytes32 indexed issuanceId, address indexed to, uint256 amount);

    // ──────────────────────────────────────────────────── custom errors ──

    /// @notice Thrown when `mintWithIssuanceId` is called with an already-used ID.
    error IssuanceAlreadyMinted(bytes32 issuanceId);

    // ─────────────────────────────────────────────────────── constructor ──

    /**
     * @notice Deploys the minter for a given token.
     * @dev The deployer becomes the owner. The deployer (or owner) must subsequently
     *      call `token.addAgent(address(this))` to grant minting authority.
     *      `DeployBase` does this immediately after construction.
     * @param _token ERC-3643 token to mint on. Must not be address(0).
     */
    constructor(address _token) {
        require(_token != address(0), "IssuanceMinter: zero token");
        token = IToken(_token);
        // msg.sender becomes owner via Ownable
    }

    // ─────────────────────────────────────────────────────── main logic ──

    /**
     * @notice Mint `amount` tokens to `to` for the given `issuanceId`, idempotently.
     * @dev Only callable by the contract owner (the deployer / backend hot key).
     *      Reverts immediately if `issuanceId` has already been presented.
     *      The issuanceId is recorded BEFORE calling `token.mint()`.
     *
     * @param to         Recipient. Must be registered in the identity registry.
     * @param amount     Number of tokens to mint. Must be > 0.
     * @param issuanceId Unique business identifier for this issuance event.
     *
     * Emits {IssuanceMinted}.
     */
    function mintWithIssuanceId(address to, uint256 amount, bytes32 issuanceId) external onlyOwner {
        require(to != address(0), "IssuanceMinter: zero recipient");
        require(amount > 0, "IssuanceMinter: zero amount");

        // ── R6: single-mint guarantee ────────────────────────────────────
        if (usedIssuanceIds[issuanceId]) {
            revert IssuanceAlreadyMinted(issuanceId);
        }

        // Mark BEFORE external call (checks-effects-interactions).
        usedIssuanceIds[issuanceId] = true;

        // ── Mint ─────────────────────────────────────────────────────────
        // Will revert if this contract is not a token agent, the recipient is
        // not verified, the token is paused, or compliance rejects.
        token.mint(to, amount);

        emit IssuanceMinted(issuanceId, to, amount);
    }
}
