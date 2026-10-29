// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Script.sol";
import "@onchain-id/solidity/contracts/Identity.sol";

import "erc3643/token/IToken.sol";
import "erc3643/registry/interface/IIdentityRegistry.sol";
import "../src/interfaces/ITransferAuthorization.sol";
import "../src/authorization/IssuanceMinter.sol";

/**
 * @title Configure
 * @author Permissioned RWA Platform
 * @notice Post-deployment configuration for a local walkthrough: registers two investors, mints an
 *         initial balance through the idempotent minter, and issues one transfer authorization.
 *
 * @dev Usage (addresses come from the `Deploy.s.sol` output):
 *      TOKEN_ADDRESS=0x... \
 *      IDENTITY_REGISTRY_ADDRESS=0x... \
 *      AUTHORIZATION_ADDRESS=0x... \
 *      ISSUANCE_MINTER_ADDRESS=0x... \
 *      forge script script/Configure.s.sol:Configure --rpc-url http://127.0.0.1:8545 --broadcast
 *
 *      INVESTOR_A / INVESTOR_B default to Anvil accounts #1 and #2 so the printed authorization can
 *      be exercised with a real key. The broadcasting account must be the owner (an identity agent
 *      and a token agent).
 */
contract Configure is Script {
    // Anvil default accounts #1 and #2 (well-known development keys).
    address internal constant ANVIL_ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant ANVIL_ACCOUNT_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    uint16 internal constant COUNTRY_US = 840;
    uint256 internal constant MINT_AMOUNT = 1_000e18;
    uint256 internal constant TRANSFER_AMOUNT = 100e18;

    function run() external {
        address investorA = vm.envOr("INVESTOR_A", ANVIL_ACCOUNT_1);
        address investorB = vm.envOr("INVESTOR_B", ANVIL_ACCOUNT_2);

        vm.startBroadcast();

        IIdentityRegistry ir = IIdentityRegistry(vm.envAddress("IDENTITY_REGISTRY_ADDRESS"));
        _registerInvestor(ir, investorA);
        _registerInvestor(ir, investorB);
        _seedMint(investorA);
        bytes32 authId = _issueAuthorization(investorA, investorB);

        vm.stopBroadcast();

        _log(investorA, investorB, authId);
    }

    /// @dev Mints the initial balance to `to` through the idempotent minter.
    function _seedMint(address to) internal {
        IssuanceMinter minter = IssuanceMinter(vm.envAddress("ISSUANCE_MINTER_ADDRESS"));
        minter.mintWithIssuanceId(to, MINT_AMOUNT, keccak256("seed-issuance-1"));
    }

    /// @dev Issues one authorization allowing `sender` -> `recipient` of `TRANSFER_AMOUNT`.
    function _issueAuthorization(address sender, address recipient) internal returns (bytes32 authId) {
        address tokenAddr = vm.envAddress("TOKEN_ADDRESS");
        ITransferAuthorization authorization = ITransferAuthorization(vm.envAddress("AUTHORIZATION_ADDRESS"));
        uint256 expiry = block.timestamp + 1 hours;
        authId = authorization.computeAuthId(tokenAddr, sender, recipient, TRANSFER_AMOUNT, expiry, 0);
        authorization.issueAuthorization(authId, tokenAddr, sender, recipient, TRANSFER_AMOUNT, expiry);
    }

    /// @dev Deploys a fresh ONCHAINID for `wallet` and registers it (claim topics are empty).
    function _registerInvestor(IIdentityRegistry ir, address wallet) internal {
        if (address(ir.identity(wallet)) != address(0)) {
            return; // already registered; keep the script idempotent
        }
        Identity id = new Identity(wallet, false);
        ir.registerIdentity(wallet, id, COUNTRY_US);
    }

    function _log(address investorA, address investorB, bytes32 authId) internal view {
        IToken token = IToken(vm.envAddress("TOKEN_ADDRESS"));
        console2.log("Registered investor A (minted):", investorA);
        console2.log("Registered investor B        :", investorB);
        console2.log("Minted amount (A)            :", MINT_AMOUNT);
        console2.log("Authorization id             :");
        console2.logBytes32(authId);
        console2.log("Authorized transfer amount   :", TRANSFER_AMOUNT);
        console2.log("Token total supply           :", token.totalSupply());
    }
}
