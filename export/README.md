# Contract sources for verification

This folder contains flattened Solidity sources so the frontend can verify share contracts on block explorers (Etherscan, Sourcify, etc.) when a share is deployed.

## Token.sol

- **Source:** ERC-3643 `Token` implementation (`lib/erc-3643/contracts/token/Token.sol`), flattened with all dependencies inlined.
- **Use:** When verifying the **implementation** contract of a deployed share (the logic contract the proxy delegates to). Use this file as the “Contract source code” in single-file verification.
- **Regenerate:** From repo root run:
  ```bash
  pnpm run export:token
  ```
  or
  ```bash
  bash scripts/export-token-source.sh
  ```

## Verification flow

1. Deploy a share via the Factory → a **TokenProxy** is deployed; its implementation is **Token**.
2. To verify the implementation on a block explorer, submit the flattened **Token.sol** from this folder as the source (single-file verification), with compiler settings: Solidity 0.8.17, optimizer enabled, 200 runs, via-IR if required to match deployment).
