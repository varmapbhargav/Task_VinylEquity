// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "@onchain-id/solidity/contracts/Identity.sol";

import "../script/DeployBase.sol";

/**
 * @title BaseTest
 * @author Permissioned RWA Platform
 * @notice Common fixture for all Foundry tests: deploys a fresh suite, registers three verified
 *         investors and seeds one of them with an initial balance.
 *
 * @dev The suite is deployed directly (see `DeployBase`). `owner` is the test contract itself, which
 *      is therefore a token agent and an identity agent. `backend` is the authorization issuer.
 */
abstract contract BaseTest is Test, DeployBase {
    Suite internal s;

    address internal owner;
    address internal backend;
    address internal alice;
    address internal bob;
    address internal carol;

    uint16 internal constant COUNTRY_US = 840;
    uint256 internal constant INITIAL_SUPPLY = 1_000_000e18;

    function setUp() public virtual {
        owner = address(this);
        backend = makeAddr("backend");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        s = _deploySuite(owner, backend);

        _registerInvestor(s, alice, COUNTRY_US);
        _registerInvestor(s, bob, COUNTRY_US);
        _registerInvestor(s, carol, COUNTRY_US);

        // Owner is a token agent, so it can mint through the minter directly in the fixture.
        s.minter.mintWithIssuanceId(alice, INITIAL_SUPPLY, keccak256("fixture-seed"));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Issues an authorization as `backend` for the default nonce (0).
    function _issueAuth(address from, address to, uint256 amount, uint256 expiry) internal returns (bytes32) {
        return _issueAuth(from, to, amount, expiry, 0);
    }

    /// @dev Issues an authorization as `backend` with an explicit nonce.
    function _issueAuth(address from, address to, uint256 amount, uint256 expiry, uint256 nonce)
        internal
        returns (bytes32 authId)
    {
        authId = s.authorization.computeAuthId(address(s.token), from, to, amount, expiry, nonce);
        vm.prank(backend);
        s.authorization.issueAuthorization(authId, address(s.token), from, to, amount, expiry);
    }

    /// @dev Issues an authorization expiring in one hour from `block.timestamp`.
    function _issueAuthOneHour(address from, address to, uint256 amount) internal returns (bytes32) {
        return _issueAuth(from, to, amount, block.timestamp + 1 hours);
    }

    /// @dev Executes an ordinary transfer as `from`.
    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        s.token.transfer(to, amount);
    }

    /// @dev Whether the authorization `authId` has been consumed.
    function _consumed(bytes32 authId) internal view returns (bool) {
        return s.authorization.getAuthorization(authId).consumed;
    }

    /// @dev The authorization id currently active for a transfer tuple.
    function _activeAuthId(address from, address to, uint256 amount) internal view returns (bytes32) {
        return s.authorization.activeAuthIdFor(address(s.token), from, to, amount);
    }
}
