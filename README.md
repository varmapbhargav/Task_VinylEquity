# Permissioned RWA Tokenization Platform

ERC-3643 (T-REX v4) permissioned token platform with off-chain authorization, reliable issuance, and chain reconciliation.

> **Status:** In progress. See the bottom of this file for known limitations and unfinished items.

## Quick links

- [DESIGN.md](./DESIGN.md) — architecture decisions
- [AI_LOG.md](./AI_LOG.md) — AI usage and errors caught
- [docs/DEPENDENCIES.md](./docs/DEPENDENCIES.md) — pinned dependency versions
- [offchain/](./offchain/) — TypeScript B1/B2/B3 modules

## Setup instructions

> Phase 1 (dependency pinning + scaffold) is complete. Application contracts and off-chain modules
> are implemented in later phases; see [Plan.md](./Plan.md) and [todolist.md](./todolist.md).

### Prerequisites

Measured on the authoring machine:

- Git `2.54.0`
- Node.js `v24.15.0`, npm `11.12.1`
- Foundry `1.8.7` (forge, cast, anvil — commit `985eeea0…`)
- Docker — **not installed**; the compose file in `infra/` is unverified.

## Dependency setup

All Solidity dependencies are pinned as git submodules. Fetch them and verify the resolved SHAs:

```bash
git submodule update --init --recursive
git submodule status
```

## T-REX release pinned

- Upstream: <https://github.com/ERC-3643/ERC-3643>
- Release: **`4.1.3`** (non-beta; the only other tag is the pre-release `4.2.0-beta1`)
- Commit: `b6c5fabf86e733ede017fef754d59eeb8f80e3f4`
- Vendored read-only at `vendor/ERC-3643/` (git submodule)

The full pinned dependency graph (versions, SHAs, licenses, remappings, and how each version was
derived from the upstream sources) is in [docs/DEPENDENCIES.md](./docs/DEPENDENCIES.md). Summary:

| Dependency | Pinned ref | Commit |
|---|---|---|
| T-REX (ERC-3643) | `4.1.3` | `b6c5fabf…` |
| ONCHAINID (`@onchain-id/solidity`) | `2.2.1` | `a483cda6…` |
| OpenZeppelin Contracts | `v4.9.6` | `dc44c9f1…` |
| OpenZeppelin Contracts Upgradeable | `v4.9.6` | `2d081f24…` |
| forge-std | `v1.9.7` | `77041d2c…` |

Solidity compiler: **0.8.17** (matches both T-REX and ONCHAINID pragmas).

## Verified build baseline (Phase 1)

```bash
cd contracts
forge build        # Compiling 62 files with Solc 0.8.17 → Compiler run successful!
forge test         # 1 passed; 0 failed  (test/unit/DependencySmoke.t.sol)

cd ../offchain
npm ci && npm run build && npm test   # tsc: 0 errors; jest: 2 passed
```

## Assumptions

> Filled in during implementation.

## Known limitations / unfinished

- Docker is not installed, so `infra/docker-compose.yml` has not been verified.
- Application contracts, off-chain modules, and their tests are not implemented yet (Phase 2+).
