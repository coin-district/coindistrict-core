#!/bin/bash
# Generate selective ABIs for published package
# This script extracts ABIs from Foundry build artifacts for contracts that consumers need

set -e

echo "🔨 Building contracts..."
forge build

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
  echo "Make sure to run 'forge build' first if contracts are missing."
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

