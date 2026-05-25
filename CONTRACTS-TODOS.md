# Contracts Security TODOs

Findings from security audit (2026-05-22). Severity, location, fix path, upgradeability.

All proxies = UUPS upgradeable. Governance + MaxSupplyModule = NOT upgradeable (redeploy only).

---

## Medium

### M1 — Oracle hardening (price bounds + per-feed staleness)
- **Where:** `SalesManager.sol:480-506` (`_getTokenUsdPrice1e8`), `:84` (global `maxOracleDelaySeconds`)
- **Chain:** Polygon PoS confirmed. Payment tokens incl. volatile (ETH/BTC) + stables (USDC/USDT).
- **Loss vector:** price reported too HIGH → `tokenAmount` too low → buyer underpays → issuer loss. `_maxPayment` does NOT protect this direction. Too-LOW → buyer overpays → `_maxPayment` reverts (safe). `minAnswer` floor-pinning (over-report vs crashed reality) maps to the dangerous direction.

**Decided design:**
1. **Sequencer check — DROPPED.** Polygon PoS has no Chainlink Sequencer Uptime Feed. Deferred to future L2 deploy via `docs/adr/0001-defer-l2-sequencer-uptime-check.md`.
2. **Price bounds — GOV CEILING ONLY.**
   - Aggregator-breaker read (A) **REJECTED**: verified on-chain 2026-05-22 that Polygon ETH/USD (`0x63db...4F5C`) and BTC/USD (`0x0144...AA63`) underlying aggregators have `minAnswer=1`, `maxAnswer=int192.max` → breakers disabled → reading them is dead code (`answer>1 && answer<3.8e57` always true). No consumer interface in lib either.
   - Static gov band (B) rejected: unmaintainable for ETH/BTC volatility.
   - **Chosen:** per-feed gov absolute ceiling `maxPrice1e8`, forced at set-time, set as a WIDE catastrophe ceiling (e.g. ETH `$50k`, BTC `$1M`), revisited rarely → volatility-proof. `buy()`: after normalizing price to 1e8, `require(price1e8 <= maxPrice1e8)`. Catches garbage-high spikes.
   - **No gov min floor:** low-price direction is `_maxPayment`-protected; floor adds config burden for ~no pinning coverage.
   - **Residual risk (documented):** garbage value *below* the ceiling (incl. within-band feed-pinning) not caught by bounds. Mitigants: tight per-feed staleness, `emergencyPaused`, time-bounded sales, gov price control. Exposure = supply minted underpriced during the window before gov pauses.
3. **Per-feed staleness.** Global `maxOracleDelaySeconds` (2h) too loose for ETH/BTC. Per-feed maxDelay ~heartbeat. **Global REMOVED** (pre-launch, no mainnet deploy): forced-at-set-time makes the fallback unreachable. Delete `maxOracleDelaySeconds` state (`:84`), `setMaxOracleDelaySeconds` (`:433`), `DEFAULT_MAX_ORACLE_DELAY_SECONDS` (`:29`), `initialize` line `:45`, `MaxOracleDelayUpdated` event. Replace with constants `MIN_ORACLE_DELAY=60s`, `MAX_ORACLE_DELAY=24h`. Migration: remove `role-and-delays.json:48`, `ProtocolFixture.sol:369`, delete `Sales.t.sol:668-682` + `RoleMatrix.t.sol:52`.
4. **Config forced at oracle-set time** (ops-mistake prevention — no feed goes live unbounded). New signature:
   `setPaymentTokenOracle(address paymentToken, address aggregator, uint256 maxDelay, uint256 maxPrice1e8)`, keyed by payment token.
   - `aggregator == address(0)` → removal path: clear oracle + bounds, skip param validation.
   - else require `maxDelay` in `[floor, 24h]`, `maxPrice1e8 > 0`, and **probe `latestRoundData()` on set** (folds in L4 — oracle validation).
   - `_getTokenUsdPrice1e8` takes `(aggregator, maxDelay, maxPrice1e8)`; `buy()` looks up per-token bounds.
- **Upgradeable:** Yes — SalesManager. New storage (per-feed maxDelay, per-feed ceiling): append after `_sales` or shrink `_gap[50]`. Global fallback preserves existing-sale behavior until gov configures per-feed.
- **MIGRATION (selector change):** signature change → new selector. (a) `role-and-delays.json` keeps the name but selector tooling must regenerate from new ABI; (b) on live deploy, post-upgrade gov must `setTargetFunctionRole(salesManager, [newSelector], SALES_CONFIG_ROLE)` (old selector now points to a non-existent fn); (c) frontend/backend ABI consumers update. `test/fixtures/ProtocolFixture.sol:364` uses `.selector` → auto-updates at compile.
- **FOLDS IN:** L4 (oracle validation on set) handled by the `latestRoundData()` probe.
- **OPERATOR GUIDE:** `docs/operations/oracle-feed-configuration.md` — how to pick static `maxDelay` + `maxPrice1e8`, maintenance triggers, pre-flight checklist.

### M2 — `deployShareSuite` bypasses MaxSupplyModule + forced agents — RESOLVED (config)
- **Where:** `Factory.sol:161-169`
- **Risk:** `createShare` forces `[TokenController, SalesManager]` agents + mandatory MaxSupplyModule (`_maxSupply>0`). `deployShareSuite` forwards caller-supplied agents (≤5) and compliance modules unchanged → uncapped token with caller-chosen agents if granted to a low-trust role.
- **Resolution:** `deployShareSuite` selector is already restricted to `PROTOCOL_ADMIN_ROLE` in `config/role-and-delays.json:37`. Normal issuance must go through `createShare` (`SHARE_DEPLOYER_ROLE`). No Factory logic change planned; `deployShareSuite` is an intentional high-trust escape hatch.
- **Residual risk:** Admin-governance risk only — a compromised `PROTOCOL_ADMIN_ROLE` holder can deploy unconstrained tokens. Mitigated by multisig governance.
- **Regression test:** `test/RoleMatrix.t.sol` — `test_shareDeployer_cannot_deploy_custom_share_suite`.

### M3 — `_authorizeUpgrade` selector mismatch breaks delayed `upgradeToAndCall` — RESOLVED
- **Where:** `SalesManager.sol:64`, `TokenController.sol:60`, `Factory.sol:90`
- **Risk:** Auth hardcoded `upgradeTo(address)` selector. Delayed AccessManager path scheduling `upgradeToAndCall` → execution-context selector mismatch → authorized upgrade reverts. Fails closed (not a hole) but config foot-gun: permissions had to target `upgradeTo` selector only.
- **Resolution:** All three `_authorizeUpgrade` overrides now authorize `msg.sig` instead of a hardcoded selector. Regression tests in `test/GovernanceDelay.t.sol` cover delayed `upgradeToAndCall` for Factory, SalesManager, and TokenController via real `AccessManager.schedule/execute`.
- **Bootstrap:** Deploy this fix to live proxies via plain `upgradeTo`, NOT `upgradeToAndCall` — currently deployed old logic still authorizes only the `upgradeTo(address)` selector until replaced. After the fix is live, delayed `upgradeToAndCall` is supported.
- **Upgradeable:** Yes — logic-only.

---

## Low / Info

### L1 — CEI ordering in `buy()`
- **Where:** `SalesManager.sol:234-253`
- **Risk:** `remainingSupply`/`saleIdToSold` updated AFTER external calls. Mitigated by `nonReentrant` + allowlisted tokens (verified via `ReentrantBuyer`). `fulfillFiatOrder` does it correctly (`:378-384`).
- **Fix:** Decrement before mint for defense-in-depth + consistency.
- **Upgradeable:** Yes — logic-only.

### L2 — Centralization / upgrade-key power
- **Where:** all UUPS contracts
- **Risk:** `upgradeTo` role holder can replace any logic → mint/drain. `setEmergencyPause`, `setPaymentTokenOracle`, `setAllowedPaymentToken`, `withdrawFunds` single-role.
- **Fix:** Execution delays on upgrade + oracle/allowlist roles, multisig admin. AccessManager config NOW.
- **Upgradeable:** Config-fixable now.

### L3 — Initializer atomicity
- **Where:** `SalesManager.sol:41`, `Factory.sol:54`, `TokenController.sol:38`
- **Risk:** `initialize` unprotected (impls protected via `_disableInitializers`). Non-atomic proxy deploy + init → front-run with hostile `governance_`.
- **Fix:** Confirm deploy script initializes in same tx. Not an upgrade matter.

### L4 — `setPaymentTokenOracle` no validation
- **Where:** `SalesManager.sol:425-428`
- **Risk:** Accepts any address, no probe. Fat-finger to bad aggregator silently mis-prices.
- **Fix:** Probe `latestRoundData`/`decimals` on set.
- **Upgradeable:** Yes — logic-only.

### L5 — `answeredInRound >= roundId` deprecated
- **Where:** `SalesManager.sol:487`
- **Risk:** Meaningless on OCR aggregators; false sense of completeness. Staleness check (`:488`) is real protection.
- **Fix:** Drop or keep as-is. Logic-only.

### I1 — `_getRemainingCap` first-match module
- **Where:** `SalesManager.sol:162-183`
- **Risk:** Cap from first module answering `getMaxSupply`. Selector collision → mis-read cap at `createSale`. Mint-time enforcement authoritative, impact bounded.

### I2 — Storage gap placement inconsistent
- **Where:** gap after `governance` in SalesManager; trailing in TokenController/Factory.
- **Risk:** Each self-consistent; safe unless post-gap vars reordered on upgrade. Document layout convention.

---

## Non-upgradeable blast radius
- **Governance:** policy mutable via AccessManager roles/delays. Contract swap needs proxy upgrade — no `setGovernance` setter (`governance` set once in `initialize`).
- **MaxSupplyModule:** bug CANNOT retro-fix live tokens. `Factory.editMaxSupplyModule` affects NEW shares only. Existing tokens need per-token ERC-3643 compliance `removeModule`/`addModule` migration. Get right pre-launch.
