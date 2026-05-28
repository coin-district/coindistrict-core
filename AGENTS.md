# CoinDistrict Core Agent Guide

Use this file for repository-specific instructions when working as an AI coding
agent. Keep `README.md` human-facing; put durable agent guidance here.

## Stack

- This is a Foundry Solidity repository for an ERC-3643 smart contract suite.
- Protocol contracts use `pragma solidity 0.8.17`.
- Governance contracts may require Solidity `0.8.22+` because OpenZeppelin v5
  `AccessManager` is enabled through `auto_detect_solc` in `foundry.toml`.
- `via_ir = true` is intentional; keep it enabled unless you have a specific
  compiler reason to change it.
- Dependencies are vendored under `lib/`; use existing remappings instead of
  inventing new import paths.

## Repository Structure

- `contracts/Factory.sol` deploys ERC-3643 share suites and wires deployed
  tokens to governance, sales, the token controller, and compliance modules.
- `contracts/SalesManager.sol` owns primary sale configuration, payment token
  handling, fiat order execution, and sale lifecycle behavior.
- `contracts/TokenController.sol` is the upgradeable ERC-3643 token agent used
  for privileged token capabilities.
- `contracts/governance/` wraps OpenZeppelin `AccessManager` behind the
  protocol governance interface.
- `contracts/compliance/` contains modular ERC-3643 compliance extensions.
- `contracts/interfaces/` and root `I*.sol` files define protocol interfaces.
- `test/fixtures/ProtocolFixture.sol` is the canonical end-to-end wiring for
  tests; reuse it before creating new deployment setup.
- `test/fixtures/Permissions.sol` and `config/role-and-delays.json` define the
  role/permission model used by tests.
- `abis/` and `export/` are generated package artifacts.

## Commands

- Build: `forge build`
- Test all: `forge test`
- Test one file: `forge test --match-path test/TokenController.t.sol`
- Test one case: `forge test --match-test test_setTokenCapsInitial_only_once_and_sets_initialized_bit`
- Format Solidity: `forge fmt`
- Package build: `pnpm build`
- Package test: `pnpm test`
- Package format: `pnpm format`
- Package lint: `pnpm lint`

## Do

- Use `config/role-and-delays.json` as the source of truth for role IDs,
  execution delays, and governed function permissions.
- Update tests when changing governance permissions, role checks, sale behavior,
  token controller capabilities, or ERC-3643 deployment wiring.
- Prefer extending `ProtocolFixture` for full protocol tests instead of copying
  setup into individual test files.
- Preserve upgradeable-contract storage layout; append storage and keep existing
  storage order stable.
- Keep contract license headers as `//SPDX-License-Identifier: GPL-3.0`.
- Run `forge fmt` after Solidity edits.
- Run `pnpm format` at the end of each task to avoid useless git diff noise
  from formatting drift.

## Do NOT

- Do NOT duplicate role IDs, execution delays, or permission mappings outside
  `config/role-and-delays.json`.
- Do NOT bypass the `Governance` / `AccessManager` authorization path for
  privileged protocol actions.
- Do NOT remove `via_ir = true` from `foundry.toml` just to work around
  stack-depth errors.
- Do NOT edit vendored dependencies under `lib/` for protocol changes.
- Do NOT hand-roll ERC-3643 registry, identity, or compliance behavior when the
  vendored suite already provides the primitive.
- Do NOT commit generated `abis/`, `export/`, `out/`, or `cache/` churn unless
  the task explicitly requires artifact updates.

## Testing Expectations

- Use focused tests for narrow contract changes and broader fixture-based tests
  for anything touching deployment wiring or cross-contract permissions.
- Cover both allowed and rejected governance paths for privileged functions.
- Add regression tests for sale math, payment token behavior, limits, and
  identity/compliance checks when those flows change.
- Keep test helpers in `test/utils/`, reusable protocol setup in
  `test/fixtures/`, and malicious or special-case test contracts in
  `test/mocks/`.
