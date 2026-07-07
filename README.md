## CoinDistrict Core

Smart contract suite for CoinDistrict, built around the ERC‑3643 standard and deployed via an upgradeable, governance‑controlled stack.

**License: GPL-3.0** — This project is licensed under the GNU General Public License v3.0. See the [LICENSE.md](LICENSE.md) file for details.

---

## Stack

- **Language & Compilers**
  - **Solidity 0.8.17** for protocol contracts (tokens, factory, controller, sales).
  - **Solidity 0.8.22+** for governance contracts (OpenZeppelin `AccessManager`‑based stack), enabled via `auto_detect_solc` in `foundry.toml`.
  - **IR pipeline**: `via_ir = true` in `foundry.toml` to avoid stack‑depth issues.

- **Tooling**
  - **Foundry** (`forge`, `cast`, `anvil`) for build, test, and debugging.
  - **Husky** for Git hooks (automatically runs `pnpm format` and exports contract sources before commits).

- **External Contracts / Libraries (vendored under `lib/`)**
  - **OpenZeppelin Contracts 4.x** and **Upgradeable**: token, proxy, and UUPS utilities.
  - **OpenZeppelin Contracts v5**: governance and `AccessManager`.
  - **ERC‑3643 suite**: compliance‑aware security token stack (`Token`, registries, modular compliance, TREX factory).
  - **OnchainID**: identity, claims, and gateways required by ERC‑3643.
  - **Chainlink Brownie Contracts**: price feed interfaces used for payment token USD oracle integration.
  - **forge‑std**: testing utilities, `stdJson`, and Foundry helpers.

Remappings for all of the above are defined in `foundry.toml` / `remappings.txt`.

---

## Project Structure

- **`contracts/`** – Core protocol contracts.
  - **`Factory.sol`** – Deploys the share/token suite (TREX‑based) and wires it to governance and sales.
  - **`SalesManager.sol`** – Handles primary sale configuration, allowed payment tokens, and sale lifecycle; governed via `AccessManager`.
  - **`TokenController.sol`** – Upgradeable controller/agent for ERC‑3643 tokens; exposes capability flags (mintable, pausable, burnable, etc.) and delegates privileged actions to the token.
  - **`governance/`** – Governance layer built on OpenZeppelin `AccessManager` plus a thin `Governance` contract used by protocol contracts.
  - **`compliance/`** – Compliance modules (e.g. `MaxSupplyModule`) that plug into the ERC‑3643 modular compliance system.
  - **`interfaces/`** – Public interfaces (`IFactory`, `ISalesManager`, `ITokenController`, `IAccessManager`, etc.).
  - **`mocks/`** – Mock contracts for testing.

- **`test/`** – Foundry tests and fixtures.
  - **`fixtures/ProtocolFixture.sol`** – End‑to‑end protocol wiring used across tests: deploys OnchainID stack, TREX factory, registries, governance (`AccessManager` + `Governance`), `SalesManager`, `TokenController`, `Factory`, and related modules.
  - **`Factory.t.sol`**, `Sales.t.sol`, `TokenController.t.sol`, `Secondary.t.sol` – High‑level protocol tests for deployment, governance, token behavior, and sales flows.
  - **`mocks/`**, `utils/` – Test‑only helpers and mock contracts.

- **`config/`**
  - **`role-and-delays.json`** – **Single source of truth** for:
    - `roleIds`: numeric role identifiers used by `AccessManager`.
    - `executionDelaysSeconds`: the timelock delays per role used by governance.
    - `permissions`: mapping of contract function names to role identifiers (for `Factory`, `SalesManager`, and `TokenController`).
  - This file is consumed by Foundry tests (via `ProtocolFixture`) and by ops/deployment tooling to keep environments in sync.

- **Root configuration & metadata**
  - **`foundry.toml`** – Foundry config (sources, libs, remappings, `via_ir`, fs permissions for `config/`).
  - **`lib/`** – Vendored external dependencies (OpenZeppelin, ERC‑3643, OnchainID, forge‑std, etc.).
  - **`package.json` / `pnpm-lock.yaml`** – JS tooling for Git hooks (Husky) (no runtime JS/TS stack in this repo).

---

## Getting Started

### Prerequisites

- **Foundry** installed globally (see Foundry docs for installation).
- Optional: a Node.js package manager (e.g. `pnpm`) if you want to run the formatting scripts.

### Install / Update Solidity Dependencies

Dependencies are vendored under `lib/`. If you need to refresh or pin them from scratch:

- OpenZeppelin (4.x + upgradeable):
  - `forge install OpenZeppelin/openzeppelin-contracts@v4.8.3 OpenZeppelin/openzeppelin-contracts-upgradeable@v4.8.3`
- OpenZeppelin v5 (governance / `AccessManager`):
  - `forge install openzeppelin-contracts-v5=OpenZeppelin/openzeppelin-contracts@v5.0.2`
- ERC‑3643:
  - `forge install ERC-3643/erc-3643@4.1.3`
- OnchainID:
  - `forge install onchain-id/solidity@2.2.1`
- Chainlink Brownie Contracts:
  - `forge install smartcontractkit/chainlink-brownie-contracts@1.3.0`

After installation, `foundry.toml` remappings will resolve imports like `@openzeppelin/contracts/...`, `@erc3643org/erc-3643/...`, and `@onchain-id/solidity/...`.

---

## Development Workflow

- **Build contracts**
  - `forge build`

- **Run all tests**
  - `forge test`

- **Run a specific test file or pattern**
  - `forge test --match-path test/TokenController.t.sol`
  - `forge test --match-test test_setTokenCapsInitial_only_once_and_sets_initialized_bit`

- **Format Solidity**
  - Run: `forge fmt` to format all Solidity files.
  - Formatting and contract source export are automatically run before each commit via Husky pre-commit hook.

---

## Governance, Roles, and Delays

The protocol uses **OpenZeppelin `AccessManager`** plus a thin `Governance` contract to control privileged actions across `Factory`, `SalesManager`, and `TokenController`.

- **Roles, IDs & delays**
  - Role IDs and delays are defined once in `config/role-and-delays.json` under `roleIds` and `executionDelaysSeconds`.
  - Consumed by tests (via `ProtocolFixture` and `_ensureRoleConfigLoaded`) to configure `AccessManager`.

- **Function permissions**
  - The `permissions` section in `config/role-and-delays.json` maps contract function names (e.g. `createShare`, `setTokenCapsInitial`, `mint`, `pause`) to roles (`ADMIN_ROLE`, `SHARE_DEPLOYER_ROLE`, etc.).
  - Both `-core` tests and `-ops` deployment scripts are expected to read from the same file to avoid configuration drift.

---

## License

This project is licensed under the **GNU General Public License v3.0 (GPL-3.0)**.

- **Full license text**: See [LICENSE.md](LICENSE.md) file in the repository root.
- **Contract headers**: All Solidity contracts include `//SPDX-License-Identifier: GPL-3.0` headers.
- **Package metadata**: Declared in `package.json` as `"license": "GPL-3.0"`.

### What GPL-3.0 means for this project

This license ensures:

- **Transparency**: All source code is publicly available for review and audit.
- **Copyleft**: Derivative works must also be licensed under GPL-3.0.
- **Freedom**: Users can use, modify, and distribute the code, subject to the license terms.

For questions about licensing or commercial licensing options, please contact the project maintainers.
