## Role & Delay Configuration Sync

Goal: keep -core test fixtures and -ops deployment scripts aligned on role assignments and execution delays by using a single, versioned configuration that both repos consume.

### Scope

- Roles defined in `AccessManager`.
- Execution delays used by `_roleExecutionDelay`.
- Function-to-role bindings for Factory, SalesManager, and TokenController.
- Delivery format that can be parsed by both Foundry (-core) and Hardhat (-ops).

### Roles and Default Execution Delays (source of truth)

- ADMIN_ROLE: 3 days
- UPGRADER_ROLE: 2 days
- SHARE_DEPLOYER_ROLE: 1 day
- SALES_OPERATOR_ROLE: 1 day
- SALES_CONFIG_ROLE: 2 days
- FUNDS_ADMIN_ROLE: 1 day
- FIAT_ORDER_ROLE: 1 day
- PAUSER_ROLE: 1 day
- MINTER_ROLE: 1 day
- BURNER_ROLE: 1 day
- FREEZER_ROLE: 1 day
- FORCE_ROLE: 1 day
- RECOVERY_ROLE: 1 day

### Function Permissions (source of truth)

- Factory
  - upgradeTo, upgradeToAndCall: UPGRADER_ROLE
  - editMaxSupplyModule, deployShareSuite: ADMIN_ROLE
  - createShare: SHARE_DEPLOYER_ROLE
- SalesManager
  - upgradeTo, upgradeToAndCall: UPGRADER_ROLE
  - rescueTokens, withdrawFunds, updateSaleFundsRecipient: FUNDS_ADMIN_ROLE
  - setAllowedPaymentToken, setPaymentTokenOracle, setMaxOracleDelaySeconds: SALES_CONFIG_ROLE
  - setEmergencyPause, unsetEmergencyPause, createSale, cancelSale, pauseSale, unpauseSale, updateSalePriceUsdPerShare, updateSaleDeadline, updateSalePaymentTokensAllowed: SALES_OPERATOR_ROLE
  - fulfillFiatOrder: FIAT_ORDER_ROLE
- TokenController
  - upgradeTo, upgradeToAndCall: UPGRADER_ROLE
  - setTokenCaps: ADMIN_ROLE
  - setTokenCapsInitial: SHARE_DEPLOYER_ROLE
  - pause, unpause: PAUSER_ROLE
  - recover: RECOVERY_ROLE
  - mint: MINTER_ROLE
  - burn: BURNER_ROLE
  - forceTransfer: FORCE_ROLE
  - setFrozen: FREEZER_ROLE

### Proposed configuration file

- Location: `config/roles-and-delays.json` (checked into -core, consumed by -ops via git submodule or pinned commit).
- Format: JSON for ease of parsing in TS/JS and Solidity tooling (can be imported in Hardhat scripts and Foundry tests).
- Content shape:

```json
{
  "executionDelaysSeconds": {
    "ADMIN_ROLE": 259200,
    "UPGRADER_ROLE": 172800,
    "SHARE_DEPLOYER_ROLE": 86400,
    "SALES_OPERATOR_ROLE": 86400,
    "SALES_CONFIG_ROLE": 172800,
    "FUNDS_ADMIN_ROLE": 86400,
    "FIAT_ORDER_ROLE": 86400,
    "PAUSER_ROLE": 86400,
    "MINTER_ROLE": 86400,
    "BURNER_ROLE": 86400,
    "FREEZER_ROLE": 86400,
    "FORCE_ROLE": 86400,
    "RECOVERY_ROLE": 86400
  },
  "permissions": {
    "Factory": {
      "upgradeTo": "UPGRADER_ROLE",
      "upgradeToAndCall": "UPGRADER_ROLE",
      "editMaxSupplyModule": "ADMIN_ROLE",
      "deployShareSuite": "ADMIN_ROLE",
      "createShare": "SHARE_DEPLOYER_ROLE"
    },
    "SalesManager": {
      "upgradeTo": "UPGRADER_ROLE",
      "upgradeToAndCall": "UPGRADER_ROLE",
      "rescueTokens": "FUNDS_ADMIN_ROLE",
      "withdrawFunds": "FUNDS_ADMIN_ROLE",
      "updateSaleFundsRecipient": "FUNDS_ADMIN_ROLE",
      "setAllowedPaymentToken": "SALES_CONFIG_ROLE",
      "setPaymentTokenOracle": "SALES_CONFIG_ROLE",
      "setMaxOracleDelaySeconds": "SALES_CONFIG_ROLE",
      "setEmergencyPause": "SALES_OPERATOR_ROLE",
      "unsetEmergencyPause": "SALES_OPERATOR_ROLE",
      "createSale": "SALES_OPERATOR_ROLE",
      "cancelSale": "SALES_OPERATOR_ROLE",
      "pauseSale": "SALES_OPERATOR_ROLE",
      "unpauseSale": "SALES_OPERATOR_ROLE",
      "updateSalePriceUsdPerShare": "SALES_OPERATOR_ROLE",
      "updateSaleDeadline": "SALES_OPERATOR_ROLE",
      "updateSalePaymentTokensAllowed": "SALES_OPERATOR_ROLE",
      "fulfillFiatOrder": "FIAT_ORDER_ROLE"
    },
    "TokenController": {
      "upgradeTo": "UPGRADER_ROLE",
      "upgradeToAndCall": "UPGRADER_ROLE",
      "setTokenCaps": "ADMIN_ROLE",
      "setTokenCapsInitial": "SHARE_DEPLOYER_ROLE",
      "pause": "PAUSER_ROLE",
      "unpause": "PAUSER_ROLE",
      "recover": "RECOVERY_ROLE",
      "mint": "MINTER_ROLE",
      "burn": "BURNER_ROLE",
      "forceTransfer": "FORCE_ROLE",
      "setFrozen": "FREEZER_ROLE"
    }
  }
}
```

Notes:

- Role identifiers (bytes32 values) live in -ops and are passed into -core fixtures; the -core file only tracks delays and permissions.
- Delays in seconds to avoid ambiguity.
- Function names must match ABI selectors used in AccessManager bindings.

### Sync process between repos

- Source of truth lives in -core (`config/roles-and-delays.json`).
- -ops consumes via git submodule or by fetching the file at a pinned commit SHA; CI validates checksum to prevent drift.
- -core tests load the same file in fixtures to configure AccessManager roles/delays.
- A lint/check script in both repos compares the live AccessManager config to the file to catch divergence before merge/deploy.

### Open items

- Decide on how to represent role IDs (bytes32 vs address). Recommendation: bytes32 keccak role IDs for clarity; map admin account addresses separately if needed.
- Add optional `defaultAdmin` and `assignedAccounts` sections if -ops needs to record which EOAs/multisigs receive each role at deployment.
- If multiple networks diverge, add a top-level `networks` map keyed by chainId to keep mainnet/testnet values explicit.
