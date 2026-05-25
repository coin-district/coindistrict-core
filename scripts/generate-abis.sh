#!/bin/bash
# Generate selective ABIs for published package
# This script extracts ABIs from Foundry build artifacts for contracts that consumers need

set -e

echo "🔨 Building package contract artifacts..."
forge build --skip test --cache-path cache/package-build \
  contracts \
  lib/erc-3643/contracts/token/Token.sol \
  lib/erc-3643/contracts/registry/implementation/IdentityRegistryStorage.sol \
  lib/erc-3643/contracts/registry/implementation/IdentityRegistry.sol \
  lib/solidity/contracts/factory/IdFactory.sol \
  lib/solidity/contracts/gateway/Gateway.sol \
  lib/solidity/contracts/ClaimIssuer.sol \
  lib/solidity/contracts/Identity.sol

# Create abis directory
mkdir -p abis

# List of contracts to export (main contracts and their interfaces)
# Exclude mocks, tests, and dependencies
CONTRACTS=(
  # Main contracts
  "Factory"
  "SalesManager"
  "TokenController"
  "Governance"
  "MaxSupplyModule"
  "Token"
  "IdentityRegistryStorage"
  "IdentityRegistry"
  "IdFactory"
  "Gateway"
  "ClaimIssuer"
  "Identity"
  "Ownable"
  "AccessManager"
  # Interfaces
  "IFactory"
  "ISalesManager"
  "ITokenController"
  "IGovernance"
  "IMaxSupplyModule"
  "IToken"
  "IIdentityRegistryStorage"
  "IIdentityRegistry"
  "IIdFactory"
  "IClaimIssuer"
  "IIdentity"
  "IAccessManager"
)

SUCCESS_COUNT=0
FAILED_COUNT=0
FAILED_CONTRACTS=()

# Extract ABIs
for contract in "${CONTRACTS[@]}"; do
  # Find the contract's JSON file (handles Foundry's out/ContractName.sol/ContractName.json structure)
  contract_file="out/${contract}.sol/${contract}.json"
  
  if [ -f "$contract_file" ]; then
    echo "✓ Extracting ABI for ${contract}"
    jq '.abi' "$contract_file" > "abis/${contract}.abi.json"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    echo "⚠ Warning: Could not find ${contract} at ${contract_file}"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_CONTRACTS+=("$contract")
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $FAILED_COUNT -eq 0 ]; then
  echo "✅ Successfully generated ${SUCCESS_COUNT} ABIs in ./abis/"
else
  echo "⚠ Generated ${SUCCESS_COUNT} ABIs, but ${FAILED_COUNT} contract(s) not found:"
  for contract in "${FAILED_CONTRACTS[@]}"; do
    echo "  - ${contract}"
  done
  echo ""
  echo "Make sure the package artifact build roots include missing contracts."
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
