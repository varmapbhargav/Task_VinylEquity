# Permissioned RWA Tokenization Platform

**Institutional tokenization infrastructure for regulated real-world assets**

[![Solidity](https://img.shields.io/badge/Solidity-0.8.x-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Testing-Foundry-orange)](https://getfoundry.sh/)
[![ERC-3643](https://img.shields.io/badge/Token%20Standard-ERC--3643-5B6FB5)](https://eips.ethereum.org/EIPS/eip-3643)
[![NestJS](https://img.shields.io/badge/Backend-NestJS-E0234E)](https://nestjs.com/)
[![PostgreSQL](https://img.shields.io/badge/Database-PostgreSQL-4169E1)](https://www.postgresql.org/)
[![TypeScript](https://img.shields.io/badge/Backend-TypeScript-3178C6)](https://www.typescriptlang.org/)

A reference implementation of a permissioned real-world asset (RWA) tokenization platform built around ERC-3643, the T-REX framework, Foundry, NestJS, and PostgreSQL.

The platform is designed to connect on-chain token operations with authoritative investor records, backend-approved transfers, reliable transaction submission, canonical blockchain event processing, reconciliation, and corporate actions.

> **Implementation status:** This README defines the intended architecture, setup, interfaces, and verification workflow. Claims about completed features, supported networks, test results, and production readiness must be confirmed against the actual repository and execution results.

---

## Table of contents

- [1. Overview](#1-overview)
- [2. Design principles](#2-design-principles)
- [3. Architecture](#3-architecture)
- [4. System components](#4-system-components)
- [5. Technology stack](#5-technology-stack)
- [6. Repository structure](#6-repository-structure)
- [7. Prerequisites](#7-prerequisites)
- [8. Installation](#8-installation)
- [9. Environment configuration](#9-environment-configuration)
- [10. Smart contract architecture](#10-smart-contract-architecture)
- [11. Transfer authorization](#11-transfer-authorization)
- [12. Issuance and transaction reliability](#12-issuance-and-transaction-reliability)
- [13. Blockchain event ingestion](#13-blockchain-event-ingestion)
- [14. Reconciliation engine](#14-reconciliation-engine)
- [15. Corporate actions: 3-for-2 split](#15-corporate-actions-3-for-2-split)
- [16. Identity and compliance](#16-identity-and-compliance)
- [17. Privileged operations and wallet recovery](#17-privileged-operations-and-wallet-recovery)
- [18. Backend API](#18-backend-api)
- [19. Database design](#19-database-design)
- [20. Security architecture](#20-security-architecture)
- [21. Testing and verification](#21-testing-and-verification)
- [22. Local development workflow](#22-local-development-workflow)
- [23. Deployment](#23-deployment)
- [24. Monitoring and operations](#24-monitoring-and-operations)
- [25. Threat model and limitations](#25-threat-model-and-limitations)
- [26. Troubleshooting](#26-troubleshooting)
- [27. Engineering documentation](#27-engineering-documentation)
- [28. Contributing](#28-contributing)
- [29. License](#29-license)

---

## 1. Overview

Tokenizing real-world assets requires more than deploying a token contract. An institutional implementation must coordinate investor eligibility, asset records, transfer restrictions, transaction execution, legal and operational controls, and the reconciliation of off-chain records with on-chain state.

This project provides an architecture for those responsibilities.

### Core capabilities

| Capability | Description |
|---|---|
| Permissioned tokenization | ERC-3643/T-REX-based token infrastructure |
| Investor eligibility | Identity and compliance checks integrated with token transfer restrictions |
| Backend-authorized transfers | Transfer-specific authorization enforced on-chain |
| Controlled issuance | Durable issuance workflows with idempotency and transaction tracking |
| Transaction reliability | Recovery from RPC timeouts, process restarts, replacements, and uncertain transaction outcomes |
| Event ingestion | Persistent processing of decoded blockchain events |
| Chain reconciliation | Detection of unexpected transfers, balance discrepancies, missing events, and inconsistent records |
| Reorganization awareness | Canonical block tracking and recovery from noncanonical observations |
| Corporate actions | Exact 3-for-2 split calculations with fractional entitlement accounting |
| Privileged operations | Controlled issuance, freezing, recovery, and approved corrective operations |
| Auditability | Persistent business references, transaction evidence, and operational records |

The architecture separates four distinct concerns:

1. **Legal and business authority:** who is entitled to an asset and who may approve an operation.
2. **Application authority:** which requests have been validated and authorized by the backend.
3. **On-chain enforcement:** which operations the smart contracts actually permit.
4. **Operational evidence:** whether transactions have succeeded and whether the observed chain state agrees with the backend's records.

These concerns are related, but none should be treated as interchangeable.

### Intended use cases

- Permissioned tokenization of eligible receivables and other financial assets.
- Issuance of regulated or compliance-restricted fungible tokens.
- Investor-controlled wallets with institutional transfer authorization.
- Corporate actions requiring exact position accounting.
- Operational monitoring and reconciliation of token activity.
- Recovery and corrective workflows requiring explicit authorization.

This project is infrastructure, not a legal opinion, custody service, KYC certification, or guarantee that a particular token represents enforceable ownership of an underlying asset.

---

## 2. Design principles

### 2.1 Standards-first implementation

Use the official [ERC-3643 specification](https://eips.ethereum.org/EIPS/eip-3643) and [T-REX implementation](https://github.com/ERC-3643/ERC-3643) as the foundation for permissioned token behavior.

Application-specific features must integrate with the selected upstream release rather than silently replacing its identity, compliance, or transfer semantics.

### 2.2 On-chain enforcement

A backend decision is not sufficient to secure a token transfer. The smart contract must enforce the required authorization and compliance rules at execution time.

### 2.3 Durable workflows

Blockchain transactions are asynchronous. A successful RPC submission does not establish that a transaction was mined, remained canonical, or reached the configured finality threshold.

Every important operation must have a durable workflow record and a defined recovery path.

### 2.4 Idempotent execution

Retries must not create duplicate business operations.

An issuance request, authorization, event, reconciliation finding, and corporate action should have an appropriate stable identifier and explicit duplicate-handling behavior.

### 2.5 Exact financial arithmetic

Token amounts and financial entitlements must use integer or exact rational arithmetic.

JavaScript floating-point numbers must not be used to represent arbitrary-precision token quantities.

### 2.6 Explicit privilege boundaries

Investor transfers, issuance, compliance administration, wallet recovery, and court-ordered corrective operations are separate capabilities. Access to one must not imply unrestricted access to the others.

### 2.7 Observable failures

The system must expose unresolved discrepancies, transaction uncertainty, ingestion lag, and operational failures. It must not silently repair important inconsistencies.

---

## 3. Architecture

### 3.1 High-level architecture

```mermaid
flowchart TB
    subgraph Clients["Clients and institutional operators"]
        Investor["Investor wallet"]
        Operator["Operations console"]
        ComplianceUser["Compliance operator"]
        Auditor["Auditor / reporting client"]
    end

    subgraph Backend["Application backend"]
        API["NestJS API"]
        Auth["Authentication and authorization"]
        Eligibility["Identity and compliance service"]
        TransferAuth["Transfer authorization service"]
        Issuance["Issuance workflow"]
        TxManager["Blockchain transaction manager"]
        EventWorker["Event ingestion worker"]
        Reconciliation["Reconciliation engine"]
        Corporate["Corporate action service"]
        Audit["Audit and operational records"]
    end

    subgraph Data["Persistent data layer"]
        DB[("PostgreSQL")]
        WorkQueue["Durable jobs / outbox"]
    end

    subgraph Chain["Blockchain layer"]
        RPC["RPC provider"]
        TReX["ERC-3643 / T-REX token"]
        Identity["Identity registry"]
        Compliance["Compliance contract"]
        Authorization["Transfer authorization enforcement"]
        Entitlement["Split entitlement ledger"]
        ChainEvents["Canonical chain events"]
    end

    Investor --> API
    Operator --> API
    ComplianceUser --> API
    Auditor --> API

    API --> Auth
    API --> Eligibility
    API --> TransferAuth
    API --> Issuance
    API --> Corporate

    TransferAuth --> DB
    Issuance --> DB
    TxManager --> DB
    EventWorker --> DB
    Reconciliation --> DB
    Corporate --> DB
    Audit --> DB

    DB <--> WorkQueue
    Issuance --> TxManager
    TransferAuth --> TxManager
    Corporate --> TxManager

    TxManager --> RPC
    RPC --> TReX
    TReX --> Identity
    TReX --> Compliance
    TReX --> Authorization
    Corporate --> Entitlement

    RPC --> ChainEvents
    ChainEvents --> EventWorker
    EventWorker --> Reconciliation
    Reconciliation --> Audit
```

The diagram describes the logical architecture. Actual deployment may combine or separate workers, APIs, and databases according to the operating environment.

### 3.2 Trust boundaries

```mermaid
flowchart LR
    subgraph Offchain["Off-chain trust boundary"]
        Business["Business records"]
        Policy["Identity and compliance decisions"]
        Signer["Authorized signing service"]
        Workflow["Durable transaction workflows"]
    end

    subgraph Onchain["On-chain enforcement boundary"]
        Signature["Authorization verification"]
        Registry["Identity registry"]
        Rules["Compliance rules"]
        Token["Permissioned token"]
    end

    subgraph Evidence["Verification boundary"]
        Events["Canonical events"]
        Balances["On-chain balances"]
        Reconcile["Reconciliation"]
    end

    Business --> Policy
    Policy --> Workflow
    Workflow --> Signer
    Signer --> Signature
    Signature --> Token
    Registry --> Token
    Rules --> Token

    Token --> Events
    Token --> Balances
    Events --> Reconcile
    Balances --> Reconcile
    Business --> Reconcile
```

**Important:** backend authorization establishes business approval, while the contract enforces the authorization supplied to it. Canonical chain evidence establishes execution state. None of these, by itself, proves the legal enforceability of the underlying asset arrangement.

---

## 4. System components

### 4.1 Smart contracts

The Solidity layer contains the official T-REX dependencies and application-owned extensions required for:

- Transfer authorization.
- Privileged-operation integration.
- Corporate-action entitlement accounting.
- Deployment and configuration.
- Unit, integration, fuzz, and invariant tests.

The official upstream implementation must remain distinguishable from application-owned code.

### 4.2 Backend API

The NestJS application exposes versioned endpoints for issuance, transfer authorization, reconciliation, corporate actions, health checks, and operational queries.

The API validates requests and persists business state before delegating asynchronous blockchain operations to durable workers.

### 4.3 Blockchain transaction manager

The transaction manager is responsible for:

- Signer and nonce coordination.
- Transaction construction and submission.
- Transaction hash persistence.
- Receipt polling.
- Replacement tracking.
- Retry classification.
- Finality evaluation.
- Recovery from uncertain outcomes.

### 4.4 Event ingestion

The event worker processes blockchain logs in deterministic order, stores block metadata, and tracks canonical checkpoints.

It supports replay and reprocessing after failures or reorganizations.

### 4.5 Reconciliation

The reconciliation engine compares backend projections with on-chain state and produces actionable discrepancy records.

It must not silently assume that a missing event, unexpected transfer, or balance difference is harmless.

### 4.6 Corporate-action service

The corporate-action service snapshots eligible positions, calculates exact entitlements, records fractional claims, and manages idempotent settlement.

---

## 5. Technology stack

| Layer | Technology | Purpose |
|---|---|---|
| Token standard | ERC-3643 / T-REX v4 | Permissioned token infrastructure |
| Smart contracts | Solidity | On-chain business rules and enforcement |
| Contract toolchain | Foundry | Compilation, deployment scripts, testing, fuzzing, invariants, gas reports |
| Contract dependencies | OpenZeppelin Contracts | Compatible reusable Solidity components |
| Identity infrastructure | ONCHAINID | Identity and claim-related integration where required by T-REX |
| Backend | Node.js, TypeScript, NestJS | APIs and background workflows |
| Blockchain client | ethers | RPC access, contract interaction, signing integration |
| Database | PostgreSQL | Durable application and operational records |
| ORM and migrations | Prisma | Database schema and migrations |
| Local blockchain | Anvil | Local development and integration testing |
| Infrastructure | Docker Compose | Reproducible local dependencies |
| API documentation | Swagger / OpenAPI | Endpoint and schema documentation |

### Version policy

The actual dependency versions must be pinned and recorded in `docs/DEPENDENCIES.md`.

The upstream T-REX source determines the compatible Solidity compiler and OpenZeppelin dependency range. Do not assume that the newest OpenZeppelin major version is compatible.

Useful primary references:

- [ERC-3643 specification](https://eips.ethereum.org/EIPS/eip-3643)
- [Official T-REX repository](https://github.com/ERC-3643/ERC-3643)
- [ONCHAINID repository](https://github.com/ERC-3643/ONCHAINID)
- [Foundry documentation](https://getfoundry.sh/)
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [NestJS documentation](https://docs.nestjs.com/)
- [Prisma documentation](https://www.prisma.io/docs)
- [PostgreSQL documentation](https://www.postgresql.org/docs/)

---

## 6. Repository structure

The following is the intended monorepo layout. The actual repository may differ; update this section to match the committed source tree.

```text
permissioned-rwa-platform/
├── contracts/
│   ├── foundry.toml
│   ├── remappings.txt
│   ├── src/
│   │   ├── authorization/
│   │   ├── corporate-actions/
│   │   ├── interfaces/
│   │   ├── libraries/
│   │   ├── adapters/
│   │   └── mocks/
│   ├── script/
│   ├── test/
│   │   ├── unit/
│   │   ├── integration/
│   │   ├── fuzz/
│   │   ├── invariant/
│   │   └── gas/
│   └── lib/
├── vendor/
│   └── ERC-3643/              # Pinned upstream source, if using a submodule
├── backend/
│   ├── src/
│   │   ├── authorization/
│   │   ├── blockchain/
│   │   ├── issuance/
│   │   ├── reconciliation/
│   │   ├── corporate-actions/
│   │   ├── identity/
│   │   ├── compliance/
│   │   ├── ledger/
│   │   ├── database/
│   │   └── health/
│   ├── prisma/
│   │   ├── schema.prisma
│   │   └── migrations/
│   └── test/
├── infra/
│   ├── docker-compose.yml
│   ├── postgres/
│   └── scripts/
├── docs/
│   ├── ARCHITECTURE.md
│   ├── THREAT_MODEL.md
│   ├── OPERATIONS.md
│   ├── API.md
│   └── DEPENDENCIES.md
├── .env.example
├── .gitignore
├── README.md
├── DESIGN.md
└── AI_LOG.md
```

---

## 7. Prerequisites

Install the following before starting development:

- Git.
- A Node.js version supported by the selected NestJS and dependency versions.
- npm.
- Foundry (`forge`, `cast`, and `anvil`).
- Docker and Docker Compose.
- PostgreSQL, if not using the supplied Docker configuration.

Verify the installations:

```bash
git --version
node --version
npm --version
forge --version
cast --version
anvil --version
docker --version
docker compose version
```

Record the versions used in the development environment when reporting reproducibility.

---

## 8. Installation

### 8.1 Clone the repository

```bash
git clone <repository-url>
cd permissioned-rwa-platform
```

Initialize submodules if the project vendors upstream sources through Git submodules:

```bash
git submodule update --init --recursive
```

Use the actual repository URL. Do not substitute an unverified upstream revision.

### 8.2 Verify upstream T-REX

Review the pinned source and its required dependency versions:

```bash
git -C vendor/ERC-3643 rev-parse HEAD
git -C vendor/ERC-3643 status --short
```

These commands assume the upstream source is present at `vendor/ERC-3643`. Adjust the path if another dependency strategy is used.

Record the exact commit and verify the corresponding compiler and dependency requirements before proceeding.

### 8.3 Install Foundry dependencies

If the repository has already pinned its dependencies, prefer its documented installation procedure.

For an existing Foundry project:

```bash
cd contracts
forge install
forge remappings
```

If the project is being initialized for the first time, install `forge-std` and the exact OpenZeppelin revision required by the pinned T-REX source.

Example commands, **only when compatible with the selected source**:

```bash
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts@v4.8.3
```

The OpenZeppelin version shown is an example, not a universal requirement. Verify the actual compatible revision first.

Configure the appropriate remappings, for example:

```text
forge-std/=lib/forge-std/src/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
```

Additional mappings may be required for ONCHAINID or other T-REX dependencies.

Compile:

```bash
forge build
```

Do not proceed by silently changing upstream contract source when a dependency mismatch appears. Resolve the actual incompatibility and document any necessary patch.

### 8.4 Install backend dependencies

```bash
cd ../backend
npm ci
```

If a committed lockfile does not exist, resolve the package versions, create the lockfile, and use `npm install` for the initial dependency resolution.

Subsequent clean installations should use `npm ci`.

### 8.5 Configure the environment

Create the local environment file from the supplied template:

```bash
cd ..
cp .env.example .env
```

On Windows PowerShell:

```powershell
Copy-Item .env.example .env
```

Set the required local database connection, chain RPC, contract addresses, and application configuration.

Never put real production credentials or private keys in `.env.example` or source control.

### 8.6 Start infrastructure

If the repository provides Docker Compose configuration:

```bash
docker compose -f infra/docker-compose.yml up -d
```

Confirm that PostgreSQL and other configured services are healthy before applying migrations.

### 8.7 Apply database migrations

```bash
cd backend
npx prisma validate
npx prisma migrate deploy
```

For a local development database, use the repository's documented development migration workflow when creating or modifying migrations.

Do not use schema-reset or destructive migration commands against a production database.

### 8.8 Start a local blockchain

In a separate terminal:

```bash
anvil
```

Configure the backend to use the local RPC endpoint printed by Anvil.

Local development keys must never be reused in production.

### 8.9 Run the application

In the contracts directory:

```bash
forge build
forge test
```

In the backend directory:

```bash
npm ci
npm run build
npm test
```

Use the actual package scripts committed in `backend/package.json`. If a script is absent, add it or document the correct equivalent rather than assuming it exists.

### 8.10 Deploy and configure contracts

Run the deployment scripts provided by the repository using the documented local-chain procedure.

The deployment process should:

1. Deploy or reference the pinned T-REX components.
2. Configure the required identity and compliance components.
3. Configure agents and roles.
4. Register the token and relevant identity infrastructure.
5. Configure the transfer authorization mechanism.
6. Verify contract addresses and configuration.
7. Save deployment metadata for backend integration.

The exact constructor arguments and configuration sequence depend on the selected T-REX release. Follow its actual source and deployment instructions.

Do not use production signing keys for local deployment.

---

## 9. Environment configuration

Maintain `.env.example` as a list of required variable names and safe placeholder values.

An illustrative configuration is:

```dotenv
NODE_ENV=development
PORT=3000
LOG_LEVEL=info

DATABASE_URL=postgresql://app:change-me@localhost:5432/rwa_platform

CHAIN_ID=31337
RPC_URL=http://127.0.0.1:8545
CHAIN_CONFIRMATION_DEPTH=2
CHAIN_POLL_INTERVAL_MS=5000

TOKEN_ADDRESS=
IDENTITY_REGISTRY_ADDRESS=
COMPLIANCE_ADDRESS=
TRANSFER_AUTHORIZATION_ADDRESS=

ISSUER_SIGNER_MODE=local
ISSUER_PRIVATE_KEY=
AUTHORIZATION_SIGNER_MODE=local
AUTHORIZATION_PRIVATE_KEY=

API_PREFIX=/api/v1
```

This list is illustrative. Retain only variables actually supported by the implementation and add any required settings discovered during integration.

### Configuration requirements

- Validate required environment variables at application startup.
- Validate addresses and chain identifiers.
- Keep private keys out of logs and API responses.
- Use managed key custody or an HSM/KMS-compatible signing integration for production.
- Configure finality according to the selected chain.
- Separate development, test, staging, and production settings.
- Avoid committing populated `.env` files.
- Use different signers for distinct security responsibilities where appropriate.

---

## 10. Smart contract architecture

### 10.1 ERC-3643/T-REX integration

ERC-3643 provides a framework for permissioned tokens with identity and compliance-oriented controls.

The platform must use the pinned upstream T-REX implementation and preserve its required transfer and administrative behavior.

The application-owned layer should contain only the additional functionality required by the system, such as transfer authorization and corporate-action entitlement accounting.

### 10.2 Conceptual contract interaction

```mermaid
flowchart TB
    User["Investor transfer request"]
    Authorization["Authorization verification"]
    Identity["Identity verification"]
    Compliance["Compliance validation"]
    Token["ERC-3643 token"]
    Event["Canonical transfer event"]

    User --> Authorization
    Authorization -->|Valid authorization| Identity
    Authorization -->|Invalid or expired| Reject["Revert"]
    Identity -->|Eligible parties| Compliance
    Identity -->|Ineligible party| Reject
    Compliance -->|Permitted| Token
    Compliance -->|Restricted| Reject
    Token --> Event
```

This is the intended logical sequence, not a claim about the exact internal execution order of every T-REX release. The implementation must confirm the real transfer path before choosing its enforcement point.

### 10.3 Foundry configuration

The `foundry.toml` file must specify the verified compiler version, optimizer settings, source paths, test paths, libraries, and remappings.

Do not use a compiler version that is incompatible with the pinned upstream dependency graph.

### 10.4 Upgradeability

If the selected T-REX components are upgradeable, document:

- Proxy type and implementation addresses.
- Initialization requirements.
- Admin authority.
- Upgrade authorization.
- Storage-layout constraints.
- Upgrade verification.
- Emergency procedures.

If a component is not upgradeable, do not add a proxy merely for convenience.

---

## 11. Transfer authorization

### 11.1 Authorization model

An ordinary transfer must be authorized against its exact parameters.

A valid authorization should bind:

- Chain ID.
- Token address.
- Source address.
- Destination address.
- Exact amount.
- Unique authorization ID or nonce.
- Expiration.
- Relevant domain and signature metadata.

The authorization must not be reusable across tokens, chains, accounts, recipients, or amounts.

### 11.2 Transfer lifecycle

```mermaid
sequenceDiagram
    autonumber
    participant I as Investor
    participant API as NestJS API
    participant DB as PostgreSQL
    participant C as Compliance Service
    participant S as Authorization Signer
    participant T as ERC-3643 Token

    I->>API: Request transfer authorization
    API->>C: Validate identity and transfer policy
    C-->>API: Decision and policy evidence
    API->>DB: Persist request and decision

    alt Transfer permitted
        API->>S: Sign exact transfer authorization
        S-->>API: Authorization signature
        API->>DB: Persist authorization metadata
        API-->>I: Return authorization
        I->>T: Submit authorized transfer
        T->>T: Verify signature and transfer constraints
        T->>T: Enforce identity and compliance rules
        T-->>I: Success or revert
    else Transfer denied
        API-->>I: Denial response
    end
```

### 11.3 Security requirements

- Validate the signer and signature domain.
- Bind the authorization to the actual token and chain.
- Consume the authorization atomically.
- Reject expired authorizations.
- Reject revoked authorizations.
- Prevent replay.
- Preserve required T-REX compliance behavior.
- Keep privileged operations separately authorized.
- Record authorization issuance, revocation, and consumption.

### 11.4 Revocation

Individual revocation invalidates a specific outstanding authorization.

Token-wide invalidation should use a mechanism appropriate to the authorization model, such as a carefully scoped epoch or generation counter.

Verify that invalidation does not inadvertently block future valid authorizations or disable privileged recovery operations.

---

## 12. Issuance and transaction reliability

### 12.1 Issuance lifecycle

```mermaid
stateDiagram-v2
    [*] --> REQUESTED
    REQUESTED --> VALIDATED
    VALIDATED --> READY_TO_SUBMIT
    VALIDATED --> REJECTED

    READY_TO_SUBMIT --> SUBMITTED
    SUBMITTED --> MINED
    SUBMITTED --> RETRYABLE_FAILURE
    SUBMITTED --> REPLACEMENT_PENDING
    SUBMITTED --> DROPPED_OR_MISSING

    RETRYABLE_FAILURE --> READY_TO_SUBMIT
    REPLACEMENT_PENDING --> SUBMITTED
    DROPPED_OR_MISSING --> READY_TO_SUBMIT

    MINED --> CONFIRMING
    CONFIRMING --> FINALIZED
    CONFIRMING --> REORGED
    REORGED --> READY_TO_SUBMIT

    MINED --> FAILED
    FINALIZED --> [*]
    REJECTED --> [*]
    FAILED --> [*]
```

The actual state machine must define permitted transitions and terminal-state semantics. For example, a failed transaction receipt must not be confused with a successful mint.

### 12.2 Idempotency

Each issuance request must carry a unique business idempotency key.

A repeated request with the same key must return the existing workflow or a consistent conflict response. It must not automatically submit a second mint.

### 12.3 RPC uncertainty

An RPC timeout may occur after a transaction was broadcast. The absence of a returned transaction hash does not prove that the transaction was never submitted.

The transaction manager should:

1. Persist the issuance request before submission.
2. Reserve the signer nonce durably.
3. Track known transaction hashes and replacements.
4. Recover uncertain submissions using available transaction and nonce evidence.
5. Inspect canonical receipts and events.
6. Resume incomplete workflows after restart.
7. Escalate unresolved ambiguity instead of blindly minting again.

### 12.4 Transaction replacement

Replacement transactions must be tracked against the original workflow, sender, and nonce.

A replacement is a new transaction attempt, not automatically a new business issuance.

The system must distinguish a fee replacement from a second independent issuance request.

### 12.5 Finality

The application must define when a transaction becomes operationally final.

Possible approaches include configurable confirmation depth or a chain-supported finalized block reference. The correct policy depends on the target network.

A transaction marked final must not be treated as permanently irreversible if the selected chain's operating assumptions do not support that conclusion.

---

## 13. Blockchain event ingestion

### 13.1 Processing model

```mermaid
flowchart LR
    RPC["Blockchain RPC"]
    Scanner["Block-range scanner"]
    Decoder["Event decoder"]
    Validator["Event validation"]
    Store[("Event and block store")]
    Checkpoint["Canonical checkpoint"]
    Reconcile["Reconciliation engine"]

    RPC --> Scanner
    Scanner --> Decoder
    Decoder --> Validator
    Validator --> Store
    Scanner --> Checkpoint
    Store --> Reconcile
    Checkpoint --> Reconcile
```

### 13.2 Required behavior

- Process events in deterministic block and log order.
- Persist transaction, log, and block metadata.
- Deduplicate events.
- Track canonical block hashes.
- Maintain resumable checkpoints.
- Support historical synchronization.
- Reprocess events when necessary.
- Distinguish provisional from finalized observations.
- Recover from partial processing failures.

### 13.3 Canonical event identity

A suitable event identifier should use the chain ID and the transaction/log identity available from the selected RPC interface.

Store the block hash as well. A log observed in a block that later becomes noncanonical must not remain authoritative merely because its transaction hash still exists in historical application records.

Use the actual event ABI from the pinned T-REX contracts.

---

## 14. Reconciliation engine

### 14.1 Purpose

The reconciliation engine compares the backend's expected state with the canonical on-chain state.

It must detect and explain discrepancies rather than silently modifying balances or inventing missing events.

### 14.2 Reconciliation workflow

```mermaid
flowchart TD
    Start["Start reconciliation run"]
    Checkpoint["Load canonical checkpoint"]
    Events["Ingest and validate events"]
    Backend["Load authoritative backend records"]
    Chain["Read block-consistent on-chain state"]
    Compare["Compare expected and observed state"]
    Finding{"Discrepancy found?"}
    Record["Persist discrepancy and evidence"]
    Clean["Record successful reconciliation"]
    Review["Investigate and authorize corrective action"]
    End["Complete run"]

    Start --> Checkpoint
    Checkpoint --> Events
    Events --> Backend
    Backend --> Chain
    Chain --> Compare
    Compare --> Finding
    Finding -->|Yes| Record
    Record --> Review
    Review --> End
    Finding -->|No| Clean
    Clean --> End
```

### 14.3 Required discrepancy categories

- Missing expected issuance.
- Unexpected mint.
- Duplicate issuance request.
- Duplicate or conflicting issuance event.
- Transfer without required authorization evidence.
- Transfer parameters inconsistent with authorization.
- Unexpected burn.
- Account balance mismatch.
- Total-supply mismatch.
- Identity or eligibility mismatch.
- Compliance-state mismatch.
- Unexpected privileged operation.
- Missing recovery evidence.
- Corporate-action entitlement mismatch.
- Event ingestion gap.
- Noncanonical transaction observation.
- Premature finality classification.

A discrepancy indicates that investigation is required; it does not automatically establish fraud.

### 14.4 Consistent state snapshots

Balance comparisons must use a defined canonical block or another consistent snapshot mechanism.

Comparing a backend projection from one chain height with a balance read from a later height can create false discrepancies.

### 14.5 Reorganization recovery

When a block becomes noncanonical:

1. Identify the affected events.
2. Mark the corresponding observations as reorged or orphaned.
3. Reverse provisional projection effects.
4. Reprocess the canonical branch.
5. Recompute affected balances and workflow states.
6. Preserve an audit record of the reorganization.
7. Avoid duplicate business operations during recovery.

### 14.6 Discrepancy records

Each discrepancy should record:

- Stable discrepancy ID.
- Category and severity.
- Chain and token.
- Affected account or business request.
- Expected value.
- Observed value.
- Transaction hash and block reference.
- Reconciliation run ID.
- First and last observed timestamps.
- Investigation status.
- Resolution reference.

---

## 15. Corporate actions: 3-for-2 split

### 15.1 Calculation

A 3-for-2 split grants three units for every two existing units.

For an eligible position \(q\):

\[
E(q)=\frac{3q}{2}
\]

The implementation must not use floating-point arithmetic or silently discard fractions.

### 15.2 Exact integer representation

For positions measured in the token's smallest base units:

\[
n=3q
\]

\[
w=\left\lfloor\frac{n}{2}\right\rfloor
\]

\[
r=n\bmod 2
\]

Where:

- \(w\) is the whole-unit entitlement.
- \(r\) is the remainder numerator.
- The remainder represents \(r/2\) of a base unit.

This representation preserves the exact result for each position.

For example, if a position contains five base units:

\[
\frac{3\times5}{2}=\frac{15}{2}=7+\frac12
\]

The result is seven whole base units plus a fractional entitlement of one-half of a base unit.

The system must not round the result up or down without an explicitly approved policy.

### 15.3 Corporate-action lifecycle

```mermaid
stateDiagram-v2
    [*] --> DRAFT
    DRAFT --> APPROVED
    APPROVED --> SNAPSHOTTING
    SNAPSHOTTING --> CALCULATED
    CALCULATED --> READY_FOR_SETTLEMENT
    READY_FOR_SETTLEMENT --> SETTLING
    SETTLING --> SETTLED
    SNAPSHOTTING --> REORG_REVIEW
    REORG_REVIEW --> SNAPSHOTTING
    SETTLING --> RECONCILIATION_REQUIRED
    RECONCILIATION_REQUIRED --> SETTLING
    SETTLED --> [*]
```

Use explicit state transitions and make settlement idempotent.

### 15.4 Snapshot requirements

Each corporate action must record:

- Corporate-action ID.
- Token and chain.
- Split ratio.
- Record date and effective date.
- Snapshot block number and hash.
- Eligible positions.
- Calculation version.
- Whole-unit entitlements.
- Fractional entitlements.
- Settlement transactions.
- Settlement status.
- Approval and audit references.

### 15.5 Conservation

The aggregate entitlement must satisfy:

\[
\sum_i E(q_i)=\frac32\sum_i q_i
\]

The sum of whole-unit settlements plus outstanding fractional entitlements must equal the exact aggregate entitlement.

If fractions are eventually settled through cash-in-lieu, a legally approved rounding policy must define the treatment of residual amounts.

### 15.6 Important limitation

A fractional entitlement recorded in an application database is not automatically a transferable token balance or proof of legal ownership. The entitlement's legal and operational treatment must be documented.

Changing token decimals is not a substitute for implementing a corporate action.

---

## 16. Identity and compliance

The platform integrates with the identity and compliance mechanisms provided by the pinned T-REX implementation.

The backend may manage:

- Investor records.
- Wallet associations.
- Eligibility decisions.
- Identity-provider references.
- Compliance evidence.
- Expiry and revocation status.
- Transfer-policy decisions.

The on-chain components must enforce the required restrictions at execution time.

### Required safeguards

- An investor must not be able to bypass transfer restrictions by calling the token directly.
- A backend approval must not override an on-chain compliance rejection.
- Identity changes must be auditable.
- Compliance decisions must be associated with a policy or business reference.
- Provider-specific KYC integrations must be isolated behind adapters.
- Sensitive personal information must not be written to public events.

This repository does not, by itself, certify that any particular KYC provider, investor, or asset meets a regulatory requirement.

---

## 17. Privileged operations and wallet recovery

### 17.1 Role separation

Privileged operations must use explicit roles and least-privilege permissions.

Separate capabilities for:

- Issuance.
- Compliance administration.
- Identity management.
- Transfer authorization.
- Wallet recovery.
- Court-ordered correction.
- Governance and upgrades.

The actual role names and access-control model must match the pinned T-REX contracts.

### 17.2 Court-ordered correction

A corrective operation should reference an approved case or order and record:

- Case reference.
- Approving authority.
- Approvers.
- Affected accounts.
- Amount.
- Reason code.
- Execution transaction.
- Resulting balances.
- Audit evidence.

A corrective operation must not be implemented as an unrestricted administrator balance-edit function.

### 17.3 Wallet recovery

Recovery must preserve the intended relationship between investor identity and assets while preventing the old wallet and recovered wallet from both exercising the same entitlement.

The design must account for:

- Lost private keys.
- Compromised wallets.
- Existing wallet restrictions.
- Identity verification.
- Transfer or recovery authorization.
- Outstanding transactions.
- Audit evidence.

The implementation must use the actual identity and recovery mechanisms supported by the chosen T-REX version or a separately reviewed extension.

---

## 18. Backend API

The API uses a versioned prefix and should publish its actual OpenAPI document through the configured Swagger endpoint.

The routes below describe the intended interface. They must be reconciled with the implemented controllers before being treated as an exhaustive API reference.

### 18.1 Health and readiness

| Method | Endpoint | Purpose |
|---|---|---|
| `GET` | `/api/v1/health` | Liveness and basic health |
| `GET` | `/api/v1/ready` | Readiness of required dependencies |

Readiness checks should verify the dependencies required for the API to perform its advertised duties.

### 18.2 Issuance

| Method | Endpoint | Purpose |
|---|---|---|
| `POST` | `/api/v1/issuances` | Submit an issuance request |
| `GET` | `/api/v1/issuances/:id` | Retrieve issuance status |
| `GET` | `/api/v1/issuances` | List issuance records |

Issuance requests must use an idempotency key and exact integer token amounts.

### 18.3 Transfer authorizations

| Method | Endpoint | Purpose |
|---|---|---|
| `POST` | `/api/v1/transfers/authorizations` | Request transfer authorization |
| `GET` | `/api/v1/transfers/authorizations/:id` | Retrieve authorization status |
| `POST` | `/api/v1/transfers/authorizations/:id/revoke` | Request revocation |

The API must authenticate the caller and verify that the caller is entitled to request or revoke the relevant authorization.

### 18.4 Reconciliation

| Method | Endpoint | Purpose |
|---|---|---|
| `POST` | `/api/v1/reconciliation/runs` | Start a reconciliation run |
| `GET` | `/api/v1/reconciliation/runs/:id` | Retrieve run status |
| `GET` | `/api/v1/reconciliation/discrepancies` | Query discrepancy records |

### 18.5 Corporate actions

| Method | Endpoint | Purpose |
|---|---|---|
| `POST` | `/api/v1/corporate-actions/splits` | Create a split proposal |
| `GET` | `/api/v1/corporate-actions/:id` | Retrieve corporate-action status |
| `POST` | `/api/v1/corporate-actions/:id/calculate` | Calculate entitlements |
| `POST` | `/api/v1/corporate-actions/:id/settle` | Execute an approved settlement |

### 18.6 API conventions

All mutation endpoints should follow these conventions:

- Authenticate and authorize the caller.
- Validate input DTOs.
- Enforce tenant isolation where applicable.
- Validate chain and contract addresses.
- Represent token quantities as decimal strings.
- Use idempotency keys where retries could create duplicate operations.
- Return durable workflow IDs for asynchronous work.
- Return consistent error structures.
- Avoid exposing private keys, signatures not intended for disclosure, or sensitive investor data.
- Record correlation IDs for operational tracing.

---

## 19. Database design

PostgreSQL is the durable store for application workflow state, authorization metadata, observed events, reconciliation records, and corporate-action calculations.

The actual Prisma schema should model the following logical entities where required.

| Entity | Purpose |
|---|---|
| Tenant | Isolation of institutional customers |
| User / service principal | API identity and access control |
| Investor | Business-level investor record |
| Wallet | Investor wallet association |
| Token | Chain and token metadata |
| Eligibility record | Identity and compliance decisions |
| Transfer authorization | Authorization parameters and lifecycle |
| Authorization revocation | Revocation evidence |
| Issuance request | Idempotent issuance workflow |
| Blockchain transaction | Transaction and receipt metadata |
| Nonce reservation | Durable signer nonce coordination |
| Transaction replacement | Replacement history |
| Block checkpoint | Canonical chain progress |
| Observed event | Decoded on-chain event record |
| Balance projection | Backend-computed balance state |
| Reconciliation run | Reconciliation execution metadata |
| Discrepancy | Identified state mismatch |
| Corporate action | Approved corporate-action metadata |
| Position snapshot | Record-date positions |
| Fractional entitlement | Exact residual claims |
| Privileged operation | Recovery and corrective-operation evidence |
| Audit event | Operational audit history |
| Outbox / work item | Durable asynchronous processing |

### Data integrity requirements

- Use database constraints to prevent duplicate business idempotency keys.
- Use unique indexes for event identities and signer/nonce reservations.
- Use foreign keys for related business records.
- Use transactions for logically atomic database operations.
- Use durable work items for asynchronous workflows.
- Preserve transaction replacement history.
- Record block hashes and canonicality information.
- Avoid relying on an unbounded mutable JSON column as the entire audit history.
- Use exact numeric representations for financial quantities.
- Preserve historical audit evidence when state changes.

The database is not the source of truth for whether an on-chain transaction actually executed. That must be established through transaction and canonical-chain verification.

---

## 20. Security architecture

### 20.1 Threats and mitigations

| Threat | Required mitigation |
|---|---|
| Transfer authorization replay | Unique authorization IDs or nonces and atomic consumption |
| Cross-chain signature replay | Chain-bound domain separation |
| Wrong recipient or amount | Exact parameter binding |
| Unauthorized mint | Restricted issuance role and audited workflow |
| Backend compromise | Least privilege, signer isolation, key rotation, monitoring |
| Nonce collision | Durable per-signer nonce coordination |
| RPC timeout after broadcast | Transaction recovery and canonical event reconciliation |
| Duplicate issuance | Business idempotency and persistent workflow state |
| Event duplication | Stable event identity and idempotent processing |
| Chain reorganization | Canonical block tracking and reversible provisional projections |
| Compliance bypass | On-chain enforcement through the selected token architecture |
| Wallet compromise | Controlled recovery, identity validation, and asset-continuity checks |
| Incorrect corporate action | Exact arithmetic, snapshots, approval, and conservation tests |
| Cross-tenant data access | Tenant-scoped authorization and database access controls |
| Sensitive data leakage | Redacted logs, secret management, and restricted API responses |
| Unauthorized reversal | Explicit roles, approvals, case references, and audit evidence |

### 20.2 Key management

Development keys and production keys must be treated differently.

For local development, use local-only accounts. For production, use an appropriate managed signing system, such as an HSM- or KMS-backed integration, subject to the chain and signer requirements.

Document:

- Key ownership.
- Signing permissions.
- Key rotation.
- Revocation and emergency response.
- Transaction approval.
- Signer availability.
- Audit logging.
- Recovery from a compromised key.

### 20.3 Administrative security

High-risk operations should have separate permissions and, where appropriate, multi-party approval.

Do not give the transfer authorization service unrestricted administrative rights over issuance, recovery, compliance configuration, or governance.

### 20.4 Security review

Passing tests does not establish that a contract is secure or production-ready.

Use appropriate static analysis, manual review, fuzzing, invariant testing, dependency review, and external audit where required by the risk profile.

---

## 21. Testing and verification

### 21.1 Foundry

Run from the contracts directory:

```bash
forge fmt --check
forge build
forge test
forge test --gas-report
```

The repository should also configure and document fuzz and invariant test profiles.

Tests should cover:

- Authorization validity.
- Expiry and revocation.
- Replay protection.
- Identity and compliance enforcement.
- Privileged roles.
- Supply and balance invariants.
- Corporate-action arithmetic.
- Exact aggregate entitlement conservation.
- Reentrancy and access-control risks where applicable.

### 21.2 Backend

Run from the backend directory:

```bash
npm ci
npx prisma validate
npm run build
npm test
```

Run the configured linting, formatting, migration, and integration-test commands as well.

### 21.3 Failure and resilience testing

Test the behavior of the system when:

- RPC submission times out.
- A process crashes after broadcast.
- A worker restarts with a pending transaction.
- A transaction is replaced.
- A transaction is dropped.
- A receipt indicates failure.
- A block is reorganized.
- An event is delivered twice.
- Events arrive out of order.
- PostgreSQL becomes unavailable.
- Two workers contend for the same nonce.
- A corporate action is retried.
- A reconciliation run is interrupted.

### 21.4 End-to-end scenarios

```mermaid
flowchart TD
    Start["Start local environment"]
    Deploy["Deploy and configure token infrastructure"]
    Investor["Create eligible test investors"]
    Issue["Issue tokens"]
    Transfer["Authorize and execute transfer"]
    Reconcile["Run reconciliation"]
    Split["Calculate and settle stock split"]
    Verify["Verify balances, supply, and entitlements"]
    Finish["Capture test and verification results"]

    Start --> Deploy
    Deploy --> Investor
    Investor --> Issue
    Issue --> Transfer
    Transfer --> Reconcile
    Reconcile --> Split
    Split --> Verify
    Verify --> Finish
```

This is the intended demonstration workflow. Execute each step and record actual results before reporting it as verified.

### 21.5 Verification reporting

Record:

- Commands executed.
- Test suites executed.
- Passed and failed tests.
- Fuzz and invariant parameters.
- Gas report results.
- Static-analysis findings.
- Dependency versions.
- Unresolved issues.

Never replace actual results with expected results or illustrative output.

---

## 22. Local development workflow

A typical local development workflow is:

1. Install and verify dependencies.
2. Start PostgreSQL.
3. Start Anvil.
4. Apply database migrations.
5. Deploy the T-REX infrastructure.
6. Configure token roles, identity registry, and compliance components.
7. Configure application addresses and signer settings.
8. Start the NestJS backend.
9. Create test investors.
10. Submit an issuance request.
11. Authorize and execute a transfer.
12. Inspect transaction and event records.
13. Run reconciliation.
14. Execute a corporate-action calculation.
15. Verify whole and fractional entitlements.
16. Run the complete test suite.

Use the repository's actual scripts for deployment, initialization, and test data.

### Suggested terminal layout

| Terminal | Process |
|---|---|
| 1 | Anvil |
| 2 | PostgreSQL / Docker Compose |
| 3 | Contract deployment and test commands |
| 4 | NestJS API |
| 5 | Background workers and reconciliation |

The actual process layout depends on how the repository packages its workers.

---

## 23. Deployment

### 23.1 Environment separation

Use distinct environments for:

- Local development.
- Automated testing.
- Staging.
- Production.

Do not reuse local accounts, database credentials, or private keys in production.

### 23.2 Predeployment checklist

- [ ] Verify pinned T-REX source and dependency commits.
- [ ] Compile using the intended compiler version.
- [ ] Run all applicable contract tests.
- [ ] Run backend tests and database migrations.
- [ ] Verify deployment parameters.
- [ ] Verify identity and compliance configuration.
- [ ] Verify transfer authorization enforcement.
- [ ] Verify signer permissions and key storage.
- [ ] Verify recovery and emergency procedures.
- [ ] Configure finality and reorganization policy.
- [ ] Verify database backup and restoration.
- [ ] Configure monitoring and alerting.
- [ ] Review the threat model.
- [ ] Review known limitations.
- [ ] Obtain required legal and security approvals.

### 23.3 Production readiness

A production deployment requires more than a successful local build.

The release process should include an appropriate security review, deployment verification, key-management review, monitoring, incident-response procedures, and operational acceptance testing.

The deployment must also establish how token rights correspond to enforceable legal arrangements in the relevant jurisdiction. ERC-3643 compliance features do not independently establish legal title to an underlying asset.

---

## 24. Monitoring and operations

Monitor the following operational indicators:

| Metric | Purpose |
|---|---|
| RPC request failures | Detect provider instability |
| Transaction submission latency | Detect execution delays |
| Pending transaction age | Detect stalled workflows |
| Replacement count | Identify fee or submission problems |
| Issuance finalization time | Measure end-to-end reliability |
| Event ingestion lag | Detect delayed indexing |
| Canonical checkpoint height | Track chain processing progress |
| Reorganization count | Detect chain instability |
| Unresolved discrepancy count | Track reconciliation health |
| Reconciliation duration | Monitor operational workload |
| Corporate-action settlement failures | Detect settlement problems |
| Database connection errors | Detect persistence failures |
| Worker retry count | Identify recurring failures |

### Incident handling

For every critical failure, operators should be able to identify:

- The affected business request.
- The current workflow state.
- The transaction hash, if known.
- The signer and nonce reservation.
- The latest canonical block checkpoint.
- Relevant event observations.
- The associated reconciliation discrepancies.
- The approved recovery procedure.

Do not automatically resubmit a potentially successful issuance merely because a monitoring alert reports a timeout.

---

## 25. Threat model and limitations

### 25.1 Out of scope unless explicitly implemented

The following must not be assumed to exist simply because they appear in the architecture:

- Production KYC provider integration.
- Custody or wallet infrastructure.
- Production HSM/KMS signing.
- Multi-party governance execution.
- A legal registry for underlying assets.
- Automatic legal enforcement of asset rights.
- Cash-in-lieu settlement.
- Production AMM integration.
- Formal verification.
- Independent security audit.
- Multi-chain production deployment.

Document each capability according to its actual implementation status.

### 25.2 AMM compatibility

Permissioned tokens require careful secondary-market design. A generic AMM may perform transfers through pool contracts or routers that do not satisfy the token's identity and compliance requirements.

Any proposed AMM integration must be reviewed against the actual T-REX transfer path, identity requirements, pool and router behavior, and applicable compliance rules.

Do not claim permissioned-token compatibility without an implemented and tested integration.

### 25.3 Legal and regulatory considerations

Technical controls cannot independently determine whether a token constitutes a security, whether a transfer is legally permitted, whether a security interest is perfected, or whether an asset-backed claim is enforceable.

Those questions depend on the asset, contractual arrangements, governing law, and relevant regulatory requirements.

The platform should reference approved legal instruments and business authorization records where required, but legal validity must be assessed separately.

---

## 26. Troubleshooting

### Foundry cannot resolve an import

Check:

```bash
forge remappings
forge build -vvv
```

Verify the actual dependency path, compiler compatibility, and remappings. Confirm that the pinned upstream repository and its transitive dependencies are present.

Do not solve a dependency mismatch by blindly installing the latest OpenZeppelin release.

### T-REX contracts do not compile with Foundry

Inspect the pinned upstream source and its official build configuration.

Determine whether the problem comes from compiler version, import resolution, dependency layout, or a genuine toolchain incompatibility.

Keep upstream source changes separate and document any necessary patch.

### PostgreSQL connection fails

Verify the database is running, the connection string is correct, and the configured database exists.

Run:

```bash
npx prisma validate
```

Then inspect the migration and database logs.

### Issuance remains pending

Inspect the persisted workflow state, transaction hashes, signer nonce, receipt, replacement history, and canonical block checkpoint.

Do not create another issuance until the original outcome has been reconciled.

### Backend and chain balances disagree

Run reconciliation against a consistent block snapshot. Inspect missing events, duplicate events, noncanonical observations, unauthorized operations, and corporate-action entries.

Do not modify the projected balance merely to make it match the chain without preserving evidence and determining the cause.

### Corporate-action totals disagree

Verify the record-date snapshot, eligibility rules, integer arithmetic, fractional entitlement denominator, excluded positions, and settlement status.

Recompute the aggregate using exact arithmetic and compare it with the original approved split calculation.

---

## 27. Engineering documentation

Maintain the following documents alongside the implementation.

| Document | Contents |
|---|---|
| `README.md` | Setup, architecture, workflows, tests, and operations |
| `DESIGN.md` | Key architecture decisions and trade-offs; maximum two pages where required |
| `AI_LOG.md` | Actual AI usage, errors discovered, and verification evidence |
| `docs/ARCHITECTURE.md` | Detailed component boundaries and data flows |
| `docs/THREAT_MODEL.md` | Assets, trust boundaries, threats, mitigations, and residual risks |
| `docs/OPERATIONS.md` | Deployment, monitoring, recovery, and incident response |
| `docs/API.md` | Actual API endpoints, schemas, and error conventions |
| `docs/DEPENDENCIES.md` | Pinned source revisions, versions, licenses, and compatibility |

Documentation must match the committed code. Remove or qualify any statement that cannot be verified.

---

## 28. Contributing

Contributions should preserve the project's standards-first, security-focused architecture.

Before submitting a change:

1. Review the relevant upstream interfaces.
2. Keep application code separate from vendor source.
3. Add tests for successful and failing paths.
4. Add fuzz or invariant tests when the change affects financial or authorization invariants.
5. Update database migrations where necessary.
6. Update documentation and configuration examples.
7. Run the relevant test and quality gates.
8. Document any unresolved risks.

### Pull request checklist

- [ ] The change has a clearly defined purpose.
- [ ] Authorization and trust boundaries remain intact.
- [ ] No secrets are committed.
- [ ] Financial calculations use exact arithmetic.
- [ ] Retries and duplicate processing are considered.
- [ ] Reorganization implications are considered.
- [ ] Tests cover expected failures.
- [ ] Documentation reflects actual behavior.

---

## 29. License

The project's license must be specified in the repository before distribution.

Review the licenses of the application code and all vendored dependencies, including T-REX, OpenZeppelin, ONCHAINID, and Foundry libraries. Preserve required notices and comply with the applicable terms.

Do not assume that every dependency has the same license as the application.

---

## Final note

The objective is not merely to issue a permissioned token. It is to build a system in which authorization, execution, investor eligibility, financial accounting, and operational evidence remain consistent across the application and the blockchain.

The most important properties are **on-chain enforcement, durable transaction handling, canonical-chain awareness, exact financial arithmetic, explicit privilege boundaries, and auditable reconciliation**.

A release should be considered ready only when these properties are demonstrated by the implementation, tests, deployment configuration, and operational procedures.