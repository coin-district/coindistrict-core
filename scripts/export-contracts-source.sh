#!/bin/bash
# Export flattened contract sources for frontend verification (Etherscan, Sourcify, etc.)
# - Token / TokenProxy: ERC-3643 share implementation and proxy (each share).
# - Identity / IdentityProxy: OnchainID identity implementation and proxy.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPORT_DIR="$REPO_ROOT/export"

mkdir -p "$EXPORT_DIR"
cd "$REPO_ROOT"

echo "Exporting Token.sol (flattened) for verification..."
forge flatten lib/erc-3643/contracts/token/Token.sol -o "$EXPORT_DIR/Token.sol"
echo "Written: $EXPORT_DIR/Token.sol"

echo "Exporting TokenProxy.sol (flattened) for verification..."
forge flatten lib/erc-3643/contracts/proxy/TokenProxy.sol -o "$EXPORT_DIR/TokenProxy.sol"
echo "Written: $EXPORT_DIR/TokenProxy.sol"

echo "Exporting Identity.sol (flattened) for verification..."
forge flatten lib/solidity/contracts/Identity.sol -o "$EXPORT_DIR/Identity.sol"
echo "Written: $EXPORT_DIR/Identity.sol"

echo "Exporting IdentityProxy.sol (flattened) for verification..."
forge flatten lib/solidity/contracts/proxy/IdentityProxy.sol -o "$EXPORT_DIR/IdentityProxy.sol"
echo "Written: $EXPORT_DIR/IdentityProxy.sol"
