# Dependencies

Everything below was resolved by **inspecting the actual upstream sources**, not by assuming
versions. Every external dependency is pinned to an immutable tag or commit.

> Status of this document: Phase 1 (dependency pinning) complete. Build and baseline tests were
> executed; see [Reproduction](#reproduction-commands) for the exact results.

---

## 1. Toolchain (measured on the authoring machine)

| Tool | Version | Notes |
|---|---|---|
| git | `2.54.0.windows.1` | Windows |
| Node.js | `v24.15.0` | |
| npm | `11.12.1` | |
| forge | `1.8.7` (commit `985eeea031d79922cd654d4e94e6c3701e1c7d73`) | |
| cast | `1.8.7` (same commit) | |
| anvil | `1.8.7` (same commit) | |
| Docker / Docker Compose | **NOT INSTALLED** | `infra/docker-compose.yml` is therefore **unverified**. |
| solc | `0.8.17` | Auto-fetched by Foundry (`svm`), matching the upstream pragma. |

**Incompatibilities / flags**

- Docker is unavailable, so the compose file cannot be validated locally. The Anvil service in it is
  disabled and left unpinned rather than inventing an image tag.
- `solc_version` and `evm_version` are pinned in `contracts/foundry.toml` so the compiler does not
  silently drift to a version that the pinned upstream sources do not support.

---

## 2. Dependency inventory

| Name | Source | Version / ref | Immutable commit | License | Compiled by |
|---|---|---|---|---|---|
| T-REX (ERC-3643) | `https://github.com/ERC-3643/ERC-3643` | tag `4.1.3` | `b6c5fabf86e733ede017fef754d59eeb8f80e3f4` | GPL-3.0 | Foundry (imported via remapping) |
| ONCHAINID (`@onchain-id/solidity`) | `https://github.com/TokenySolutions/ONCHAINID` | tag `2.2.1` | `a483cda6821e3883497972d36d0c4c1e1693e483` | ISC | Foundry |
| OpenZeppelin Contracts | `https://github.com/OpenZeppelin/openzeppelin-contracts` | tag `v4.9.6` | `dc44c9f1a4c3b10af99492eed84f83ed244203f6` | MIT | Foundry |
| OpenZeppelin Contracts Upgradeable | `https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable` | tag `v4.9.6` | `2d081f24cac1a867f6f73d512f2022e1fa987854` | MIT | Foundry |
| forge-std | `https://github.com/foundry-rs/forge-std` | tag `v1.9.7` | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | MIT OR Apache-2.0 | Foundry |
| ethers (offchain) | npm `ethers` | `^6.13.4` (resolved in `offchain/package-lock.json`) | — | MIT | Node / ts-jest |

Vendoring layout:

- `vendor/ERC-3643/` — upstream T-REX, added as a **git submodule** at the repo root and kept
  read-only. Application contracts never live here.
- `contracts/lib/` — Foundry dependencies (`forge-std`, OpenZeppelin, ONCHAINID), each a submodule
  pinned to the tag/commit above. Reproduce with `git submodule status`.

---

## 3. How the versions were derived (not assumed)

1. `git ls-remote --tags https://github.com/ERC-3643/ERC-3643.git` returned exactly two tags:
   `4.1.3` and `4.2.0-beta1`. `4.1.3` (a non-beta release) was selected; `4.2.0-beta1` was rejected
   as a pre-release.
2. `vendor/ERC-3643/package.json` (v4.1.3) declares `@openzeppelin/contracts ^4.8.3`,
   `@openzeppelin/contracts-upgradeable ^4.8.3`, `@onchain-id/solidity ^2.0.0`.
3. `vendor/ERC-3643/package-lock.json` — the exact versions upstream CI resolved — pins
   **OpenZeppelin `4.9.6`** and **`@onchain-id/solidity` `2.2.1`**. Those exact versions were used
   in preference to the looser `package.json` ranges. This is why the build uses OZ **4.9.6** and not
   the `4.8.3` shown in illustrative documentation.
4. `vendor/ERC-3643/hardhat.config.ts` sets the compiler to **`0.8.17`** with the optimizer enabled
   at 200 runs; `contracts/foundry.toml` mirrors that.
5. The `ERC-3643/ONCHAINID` repository's `main` branch is now **v3.0.0**, a full rewrite
   (Foundry-based, ERC-7579/ERC-4337) that is **incompatible** with T-REX v4.1.3. The v2.x line that
   T-REX actually imports (`@onchain-id/solidity/contracts/interface/IIdentity.sol`) lives at
   `TokenySolutions/ONCHAINID` tag `2.2.1`. That source was inspected directly: it uses
   `pragma solidity 0.8.17;`, exposes `contracts/interface/IIdentity.sol`, and imports
   `@openzeppelin/contracts/*`.
6. Import analysis of `vendor/ERC-3643/contracts/**` confirmed the exact prefixes that need
   remapping: `@openzeppelin/contracts/…`, `@openzeppelin/contracts-upgradeable/…`,
   `@onchain-id/solidity/contracts/…`.

---

## 4. Remappings

`contracts/remappings.txt`:

```text
forge-std/=lib/forge-std/src/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/
@onchain-id/solidity/=lib/ONCHAINID/
erc3643/=../vendor/ERC-3643/contracts/
```

Foundry additionally auto-derives `ERC-3643/=../vendor/ERC-3643/contracts/` and
`ONCHAINID/=lib/ONCHAINID/contracts/` from `libs = ["lib", "../vendor"]`.

---

## 5. Reproduction commands

```bash
# 1. Fetch pinned Solidity dependencies (submodules)
git submodule update --init --recursive
git submodule status        # prints the exact SHAs listed in the inventory above

# 2. Foundry config sanity
cd contracts
forge remappings            # must list the five remappings in section 4
forge build                 # compiles the upstream dependency graph
forge test                  # baseline: DependencySmoke.t.sol

# 3. Off-chain TypeScript
cd ../offchain
npm ci
npm run build               # tsc --noEmit
npm test                    # jest
```

### Results actually observed (authoring machine)

| Command | Result |
|---|---|
| `git submodule status` | 5 submodules at the SHAs listed above; `../vendor/ERC-3643` at `4.1.3`. |
| `forge build` | `Compiling 62 files with Solc 0.8.17` → `Compiler run successful!` (0 errors). |
| `forge test` | `1 passed; 0 failed` (`test/unit/DependencySmoke.t.sol`). |
| `npm ci` | 306 packages installed, 0 errors. |
| `npm run build` | `tsc --noEmit` completed with 0 errors. |
| `npm test` | `2 passed, 2 total`. |

---

## 6. Security-review status

| Dependency | Status |
|---|---|
| T-REX v4.1.3 | Upstream reference implementation; not audited by the author. GPL-3.0 — review obligations before redistribution. |
| ONCHAINID 2.2.1 | Upstream reference implementation; not audited by the author. |
| OpenZeppelin v4.9.6 | Widely used; upstream audits exist. Pinned to the version T-REX itself resolves. |
| forge-std v1.9.7 | Test-only tooling; not deployed. |
| ethers v6 | Runtime library only; not deployed. |

No dependency in this project has been audited by the author, and no security claim is implied by a
successful build.

---

## 7. Known build limitations

- Upstream T-REX and ONCHAINID are **Hardhat** projects. This repository consumes their Solidity
  sources through Foundry remappings and does **not** modify them. Hardhat's own build/test commands
  were **not** run as an independent verification path in this phase.
- Foundry's `gas_reports = ["*"]` is enabled in `contracts/foundry.toml`; gas numbers appear only
  after application contracts exist and `forge test --gas-report` is run.
- The Docker compose file is unverified (Docker unavailable).
