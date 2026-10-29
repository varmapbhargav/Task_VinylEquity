// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

// Dependency-integration smoke test.
// Its sole purpose is to force the compiler to resolve the full dependency graph
// (T-REX v4.1.3 + ONCHAINID 2.2.1 + OpenZeppelin 4.9.6) through the remappings in
// `contracts/remappings.txt`. It asserts no application behaviour.
import {Test} from "forge-std/Test.sol";

import {IToken} from "erc3643/token/IToken.sol";
import {Token} from "erc3643/token/Token.sol";
import {IModularCompliance} from "erc3643/compliance/modular/IModularCompliance.sol";
import {ModularCompliance} from "erc3643/compliance/modular/ModularCompliance.sol";
import {AbstractModule} from "erc3643/compliance/modular/modules/AbstractModule.sol";
import {IModule} from "erc3643/compliance/modular/modules/IModule.sol";
import {IdentityRegistry} from "erc3643/registry/implementation/IdentityRegistry.sol";
import {IdentityRegistryStorage} from "erc3643/registry/implementation/IdentityRegistryStorage.sol";
import {ClaimTopicsRegistry} from "erc3643/registry/implementation/ClaimTopicsRegistry.sol";
import {TrustedIssuersRegistry} from "erc3643/registry/implementation/TrustedIssuersRegistry.sol";
import {IIdentityRegistry} from "erc3643/registry/interface/IIdentityRegistry.sol";

import {Identity} from "@onchain-id/solidity/contracts/Identity.sol";
import {ClaimIssuer} from "@onchain-id/solidity/contracts/ClaimIssuer.sol";
import {IIdentity} from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract DependencySmokeTest is Test {
    // Referencing the imported symbols keeps the dependency graph reachable so
    // `forge build` compiles the upstream contracts rather than skipping them.
    function _referenceGraph()
        internal
        pure
        returns (
            IToken,
            Token,
            IModularCompliance,
            ModularCompliance,
            AbstractModule,
            IModule,
            IdentityRegistry,
            IdentityRegistryStorage,
            ClaimTopicsRegistry,
            TrustedIssuersRegistry,
            IIdentityRegistry,
            Identity,
            ClaimIssuer,
            IIdentity,
            Ownable,
            OwnableUpgradeable
        )
    {
        revert("compile-only reference");
    }

    function test_dependencyGraphCompiles() public view {
        assertTrue(address(this) != address(0));
    }
}
