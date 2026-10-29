// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "erc3643/compliance/modular/modules/AbstractModule.sol";
import "erc3643/compliance/modular/IModularCompliance.sol";
import "erc3643/token/IToken.sol";
import "../interfaces/ITransferAuthorization.sol";

/**
 * @title TransferAuthorizationModule
 * @notice ERC-3643 compliance module that enforces backend transfer authorization.
 *
 * ─── DESIGN RATIONALE (Part C) ───────────────────────────────────────────────
 *
 * PLACEMENT — Compliance module (not token extension, not adapter contract):
 *
 *   1. Token extension (`_beforeTokenTransfer` override): Would require modifying
 *      the upstream T-REX token contract, breaking upgradeability and making
 *      auditing harder. Ruled out.
 *
 *   2. Separate adapter/wrapper: Breaks ERC-20 UX — investors would not call
 *      `token.transfer()` but a custom adapter. Ruled out.
 *
 *   3. Compliance module (chosen): `canTransfer` / `moduleCheck` is the designed
 *      integration point for per-transfer business rules. Key properties:
 *        - Token is never modified.
 *        - Agent operations (`forcedTransfer`, `mint`, `burn`, `freeze`,
 *          wallet recovery) use code paths that do NOT call `canTransfer`,
 *          so they naturally bypass this module (R5 compliance).
 *        - `mint` DOES call `canTransfer(address(0), to, amount)` — we handle
 *          `from == address(0)` as a mint bypass explicitly.
 *        - The `moduleTransferAction` hook (called after the transfer succeeds)
 *          performs the actual consumption (state change), keeping `moduleCheck`
 *          a pure view as required by the interface.
 *
 * AUTHORIZATION RESOLUTION:
 *   The compliance calls `moduleCheck(from, to, value, compliance)` — it does
 *   NOT pass an authId. We resolve the active authorization by calling
 *   `ITransferAuthorization.activeAuthIdFor(token, from, to, value)`, which
 *   the `TransferAuthorization` contract maintains in an O(1) slot mapping.
 *   This avoids any `tx.origin` abuse and any off-chain "prepare" step.
 *
 * ATOMICITY:
 *   `moduleCheck` (view) — validates without consuming.
 *   `moduleTransferAction` (state-changing, onlyComplianceCall) — consumes.
 *   Because `moduleTransferAction` is called by the compliance AFTER the ERC-20
 *   transfer has already been committed, there is no re-entrancy risk: the
 *   consumed flag is set after balances have moved.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 */
contract TransferAuthorizationModule is AbstractModule {

    /// @notice The transfer authorization registry.
    ITransferAuthorization public immutable transferAuthorization;

    constructor(address _authRegistry) {
        require(_authRegistry != address(0), "TAM: zero address");
        transferAuthorization = ITransferAuthorization(_authRegistry);
    }

    // ─────────────────────────────────────────────────────── IModule hooks ──

    /**
     * @inheritdoc IModule
     * @dev Pure view check; does NOT consume the authorization.
     *
     *      Bypass conditions (return `true` without checking auth):
     *        - `_from == address(0)`: This is a mint call. T-REX `mint()` calls
     *          `canTransfer(address(0), to, amount)` through compliance. Agents
     *          already hold the AGENT role and this code path is always operator-
     *          initiated. We allow it unconditionally so mints are never blocked.
     *        - No bypass is needed for `forcedTransfer` / `burn` / freeze / recovery
     *          because those functions do NOT call `canTransfer` in T-REX v4.
     */
    function moduleCheck(
        address _from,
        address _to,
        uint256 _value,
        address _compliance
    ) external view override returns (bool) {
        // Mint path: from == address(0). Agent-only. Always permit.
        if (_from == address(0)) return true;

        address token = IModularCompliance(_compliance).getTokenBound();

        // Resolve the active authorization for this transfer tuple.
        bytes32 authId = transferAuthorization.activeAuthIdFor(token, _from, _to, _value);
        if (authId == bytes32(0)) return false;

        // Validate it is still usable (not expired, not consumed, not revoked, same epoch).
        return transferAuthorization.isValid(authId, token, _from, _to, _value);
    }

    /**
     * @inheritdoc IModule
     * @dev Called by ModularCompliance AFTER the ERC-20 transfer succeeds.
     *      Consumes the authorization atomically.
     *
     *      Bypass: `_from == address(0)` (mint action — no auth to consume).
     *      All other agent paths (forcedTransfer, burn) call `destroyed()` / no
     *      compliance hook here, so they never reach this function.
     */
    function moduleTransferAction(
        address _from,
        address _to,
        uint256 _value
    ) external override onlyComplianceCall {
        // Mint path has no authorization to consume.
        if (_from == address(0)) return;

        address token = IModularCompliance(msg.sender).getTokenBound();

        bytes32 authId = transferAuthorization.activeAuthIdFor(token, _from, _to, _value);
        if (authId == bytes32(0)) return; // defensive — should not be reached in a valid flow

        // Consume: marks as consumed and clears the active slot in the registry.
        transferAuthorization.consumeAuthorization(authId, token, _from, _to, _value);
    }

    /**
     * @inheritdoc IModule
     * @dev Mint actions are handled by the `_from == address(0)` bypass in
     *      `moduleCheck` / `moduleTransferAction`. No extra state here.
     */
    function moduleMintAction(address /*_to*/, uint256 /*_value*/) external override onlyComplianceCall {
        // No state update required; mints are agent-only and always permitted.
    }

    /**
     * @inheritdoc IModule
     * @dev Burns never go through the compliance `canTransfer` path in T-REX v4,
     *      but `destroyed()` is called, which calls `moduleBurnAction`. No auth state.
     */
    function moduleBurnAction(address /*_from*/, uint256 /*_value*/) external override onlyComplianceCall {
        // No state update required; burns are agent-only and always permitted.
    }

    // ───────────────────────────────────────────────────── IModule metadata ──

    /**
     * @inheritdoc IModule
     * @dev `canComplianceBind` returns `true` — no pre-condition on the compliance.
     */
    function canComplianceBind(address /*_compliance*/) external pure override returns (bool) {
        return true;
    }

    /**
     * @inheritdoc IModule
     * @dev `isPlugAndPlay()` returns `true` — no per-compliance configuration
     *      is needed beyond constructing with the authorization registry address.
     *      (The previous design returned `false` because it used `prepareTransfer`.
     *       Now that the module resolves authId from `activeAuthIdFor`, no setup
     *       step is required, so it qualifies as plug-and-play.)
     */
    function isPlugAndPlay() external pure override returns (bool) {
        return true;
    }

    /**
     * @inheritdoc IModule
     */
    function name() external pure override returns (string memory) {
        return "TransferAuthorizationModule";
    }
}
