# Contract sources for verification

This folder contains flattened Solidity sources so the frontend can verify contracts on block explorers (Etherscan, Sourcify, etc.) when shares or identities are deployed.

## Token.sol

- **Source:** ERC-3643 `Token` implementation (`lib/erc-3643/contracts/token/Token.sol`), flattened with all dependencies inlined.
- **Use:** When verifying the **implementation** contract of a deployed share (the logic contract the proxy delegates to). Use this file as the “Contract source code” in single-file verification.

## TokenProxy.sol

- **Source:** ERC-3643 `TokenProxy` (`lib/erc-3643/contracts/proxy/TokenProxy.sol`), flattened with all dependencies inlined.
- **Use:** When verifying the **proxy** contract at the share address (the contract users interact with). Use this file as the “Contract source code” in single-file verification. Constructor args: implementation authority, identity registry, compliance, name, symbol, decimals, onchainID.

## Identity.sol

- **Source:** OnchainID `Identity` implementation (`lib/solidity/contracts/Identity.sol`), flattened with all dependencies inlined.
- **Use:** When verifying the **implementation** contract of an identity (the logic contract the identity proxy delegates to).

## IdentityProxy.sol

- **Source:** OnchainID `IdentityProxy` (`lib/solidity/contracts/proxy/IdentityProxy.sol`), flattened with all dependencies inlined.
- **Use:** When verifying the **proxy** contract at the identity address (the contract users interact with for onchain identity).

## Regenerate

From repo root run:

```bash
pnpm run export:contracts
```

or

```bash
bash scripts/export-contracts-source.sh
```

All four files (**Token.sol**, **TokenProxy.sol**, **Identity.sol**, **IdentityProxy.sol**) are written to this folder.

## Verification flow (shares)

1. Deploy a share via the Factory → a **TokenProxy** is deployed; its implementation is **Token**.
2. **Proxy (share address):** Verify using flattened **TokenProxy.sol** with the correct constructor arguments.
3. **Implementation:** Verify using flattened **Token.sol** (single-file verification). Compiler settings: Solidity 0.8.17, optimizer enabled, 200 runs, via-IR if required to match deployment.
