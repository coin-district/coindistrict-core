#!/bin/bash
# Export flattened Token.sol for frontend contract verification (Etherscan, Sourcify, etc.)
# The Token contract is the ERC-3643 share implementation used behind the proxy when a share is deployed.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPORT_DIR="$REPO_ROOT/export"
TOKEN_SOURCE="lib/erc-3643/contracts/token/Token.sol"
OUTPUT_FILE="$EXPORT_DIR/Token.sol"

mkdir -p "$EXPORT_DIR"

echo "Exporting Token.sol (flattened) for verification..."
cd "$REPO_ROOT"
forge flatten "$TOKEN_SOURCE" -o "$OUTPUT_FILE"
echo "Written: $OUTPUT_FILE"
