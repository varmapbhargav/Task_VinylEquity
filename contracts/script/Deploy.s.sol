// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Script.sol";
import "./DeployBase.sol";

/**
 * @title Deploy
 * @author Permissioned RWA Platform
 * @notice Deploys the full RWA stack to the configured RPC (Anvil by default) and prints every
 *         deployed address.
 *
 * @dev Usage:
 *      forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast
 *
 *      The broadcasting account becomes the owner of every contract. Optionally set
 *      `BACKEND_SIGNER` to grant the authorizer role to a separate backend key; it defaults to the
 *      broadcasting account.
 */
contract Deploy is Script, DeployBase {
    function run() external returns (Suite memory s) {
        vm.startBroadcast();

        address owner = msg.sender;
        address backendSigner = vm.envOr("BACKEND_SIGNER", owner);

        s = _deploySuite(owner, backendSigner);

        vm.stopBroadcast();

        console2.log("Owner                       :", owner);
        console2.log("Backend signer (authorizer) :", backendSigner);
        console2.log("ClaimTopicsRegistry         :", address(s.ctr));
        console2.log("TrustedIssuersRegistry      :", address(s.tir));
        console2.log("IdentityRegistryStorage     :", address(s.irs));
        console2.log("IdentityRegistry            :", address(s.ir));
        console2.log("ModularCompliance           :", address(s.mc));
        console2.log("Token                       :", address(s.token));
        console2.log("TransferAuthorization       :", address(s.authorization));
        console2.log("TransferAuthorizationModule :", address(s.module));
        console2.log("IssuanceMinter              :", address(s.minter));
    }
}
