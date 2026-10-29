// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "erc3643/registry/implementation/ClaimTopicsRegistry.sol";
import "erc3643/registry/implementation/TrustedIssuersRegistry.sol";
import "erc3643/registry/implementation/IdentityRegistryStorage.sol";
import "erc3643/registry/implementation/IdentityRegistry.sol";
import "erc3643/compliance/modular/ModularCompliance.sol";
import "erc3643/token/Token.sol";
import "@onchain-id/solidity/contracts/Identity.sol";

import "../src/authorization/TransferAuthorization.sol";
import "../src/authorization/TransferAuthorizationModule.sol";
import "../src/authorization/IssuanceMinter.sol";

/**
 * @title DeployBase
 * @author Permissioned RWA Platform
 * @notice Shared, upgrade-free deployment of a complete RWA stack, reused by `Deploy.s.sol`,
 *         `Configure.s.sol` and the Foundry test suite.
 *
 * @dev DEPLOYMENT STRATEGY / WHY NOT THE PROXY FACTORY:
 *      T-REX ships a full CREATE2 + `TREXImplementationAuthority` + `TREXFactory` topology. That is
 *      the production route and it exists to make the suite *upgradeable* and *address-deterministic*.
 *      For this deliverable we deploy the implementation contracts directly and initialise them once:
 *        - every T-REX contract here is an `Initializable` implementation whose `init()` can be run
 *          on the deployed contract itself (all state lives locally, no delegatecall needed);
 *        - it removes ~6 extra contracts (IA, IAFactory, TREXFactory, ONCHAINID IdFactory/IA) and the
 *          CREATE2 salt bookkeeping, which keeps the demo hermetic and the tests fast;
 *        - the trade-off (no upgradeability, no cross-chain deterministic addresses) is documented in
 *          `DESIGN.md`; nothing about the authorization design depends on it.
 *
 *      The `owner` argument is the address that ends up owning every contract. It must equal the
 *      caller (`msg.sender`) in whichever context this runs — the broadcasting EOA in a script, or
 *      the test contract in Foundry tests — because every `init()`/`addAgent()` call below executes
 *      as that caller.
 */
abstract contract DeployBase is ITransferAuthorization {
    /// @notice Addresses of every contract in the deployed stack.
    /// @dev DeployBase inherits ITransferAuthorization so that all test contracts extending BaseTest
    ///      have the authorization events in their inheritance scope. Under Solidity 0.8.17, the
    ///      `emit ITransferAuthorization.EventName()` pattern in vm.expectEmit tests requires the
    ///      emitting type to be in the contract's inheritance chain.
    struct Suite {
        ClaimTopicsRegistry ctr;
        TrustedIssuersRegistry tir;
        IdentityRegistryStorage irs;
        IdentityRegistry ir;
        ModularCompliance mc;
        Token token;
        TransferAuthorization authorization;
        TransferAuthorizationModule module;
        IssuanceMinter minter;
    }

    /// @notice Token metadata used by the demo deployment.
    string internal constant TOKEN_NAME = "Permissioned RWA Token";
    string internal constant TOKEN_SYMBOL = "PRWA";
    uint8 internal constant TOKEN_DECIMALS = 18;

    /**
     * @notice Deploys and wires the whole stack, owned by `owner`.
     * @param owner Address that will own the token, registries, compliance and authorization
     *        registry, and that acts as a token/identity agent for setup. MUST equal `msg.sender`.
     * @param backendSigner Address granted the authorizer role on `TransferAuthorization`.
     * @return s The deployed suite.
     */
    function _deploySuite(address owner, address backendSigner) internal returns (Suite memory s) {
        // --- registries ---------------------------------------------------
        s.ctr = new ClaimTopicsRegistry();
        s.ctr.init();

        s.tir = new TrustedIssuersRegistry();
        s.tir.init();

        s.irs = new IdentityRegistryStorage();
        s.irs.init();

        s.ir = new IdentityRegistry();
        s.ir.init(address(s.tir), address(s.ctr), address(s.irs));
        // Registers `ir` as an agent of `irs` so it can write identities through the storage.
        s.irs.bindIdentityRegistry(address(s.ir));

        // --- compliance + token ------------------------------------------
        s.mc = new ModularCompliance();
        s.mc.init();

        s.token = new Token();
        s.token.init(address(s.ir), address(s.mc), TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS, address(0));

        // --- our authorization layer -------------------------------------
        s.authorization = new TransferAuthorization(owner, backendSigner);
        s.module = new TransferAuthorizationModule(address(s.authorization));
        // Owner-only on the compliance; the caller here is `owner`.
        s.mc.addModule(address(s.module));
        // Owner-only on the registry; lets the module consume authorizations.
        s.authorization.addConsumer(address(s.module));

        // --- idempotent issuance -----------------------------------------
        s.minter = new IssuanceMinter(address(s.token));

        // --- roles --------------------------------------------------------
        // The identity registry needs the token as agent (mirrors TREXFactory behaviour) and the
        // owner so investors can be registered by the operator.
        s.ir.addAgent(address(s.token));
        s.ir.addAgent(owner);
        // The token needs the owner (for freeze/forcedTransfer/recovery/unpause) and the minter.
        s.token.addAgent(owner);
        s.token.addAgent(address(s.minter));

        // T-REX tokens start paused; the owner is an agent, so it can unpause.
        s.token.unpause();
    }

    /**
     * @notice Deploys a fresh ONCHAINID for `wallet` and registers it in the identity registry.
     * @dev The registry's claim-topics list is empty, and `IdentityRegistry.isVerified` returns
     *      `true` for any registered identity when no claim topics are required — so a registered
     *      investor is immediately transferable without issuing claims.
     * @param s The deployed suite.
     * @param wallet Wallet address to register (also used as the identity's management key).
     * @param country ISO-3166 numeric country code.
     * @return id The created ONCHAINID contract.
     */
    function _registerInvestor(Suite memory s, address wallet, uint16 country) internal returns (Identity id) {
        id = new Identity(wallet, false);
        s.ir.registerIdentity(wallet, id, country);
    }
}
