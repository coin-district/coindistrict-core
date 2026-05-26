# HANDOFF-FIX-SALES-INVARIANT - Make rejected sales invariant actions observable

## 1. Goal

Fix the rejected-operation coverage added to `test/SalesInvariant.t.sol`. The
current handlers attempt to fail on an unexpected successful `buy()` or
`fulfillFiatOrder()` by reverting the handler call or by using
`vm.expectRevert`; however, both invariant profiles configure
`fail_on_revert = false`, so Foundry can discard the failing handler
transaction and lose the state that proves the protocol regression. Replace
that behavior with persistent violation state in the handler and invariants
that fail after any forbidden operation succeeds, returns the wrong emergency
pause error, or changes observable state.

## 2. Files to Touch

- `/home/akhos/coindistrict/coindistrict-core/test/SalesInvariant.t.sol` -
  replace discard-prone rejected-path checks with persistent violation
  tracking and add invariants for those violations.

Do not modify `/home/akhos/coindistrict/coindistrict-core/foundry.toml`; the
test must be reliable under the repository's existing invariant settings.

## 3. Step-by-Step Tasks

1. Read the current handler actions
   `buyWithZeroAllowanceReverts`, `fulfillFiatToUnregisteredReverts`,
   `buyWhileEmergencyPausedReverts`, and
   `fulfillFiatWhileEmergencyPausedReverts`, plus the invariant profile in
   `foundry.toml`. Preserve the already-added oracle mutation, amount
   chunking, supply-cap alignment, selector targeting, and accounting
   invariants.

2. Add persistent boolean violation fields to `SalesInvariantHandler` for
   each rejected behavior being exercised. Use clear names such as:

   ```solidity
       bool public zeroAllowanceBuySucceeded;
       bool public unregisteredFiatFulfillmentSucceeded;
       bool public pausedBuyViolation;
       bool public pausedFiatViolation;
   ```

   The paused flags may represent either unexpected success or an unexpected
   revert reason, because both outcomes violate the action's contract.

3. Rewrite `buyWithZeroAllowanceReverts(uint256 amount)` so an unexpected
   successful `protocol.salesManager.buy(...)` sets
   `zeroAllowanceBuySucceeded = true` and returns normally. Do not use
   `revert("... expected revert")` in the success branch. Retain the existing
   setup that gives the buyer tokens, clears the allowance, and submits an
   otherwise valid amount; it is needed to reach the post-accounting
   `safeTransferFrom` failure path.

4. Rewrite `fulfillFiatToUnregisteredReverts(uint256 amount, uint256 refSeed)`
   so an unexpected successful fiat fulfillment sets
   `unregisteredFiatFulfillmentSucceeded = true` and returns normally. Do not
   revert the handler after protocol success. Continue using `acc.user1` as
   the unregistered recipient; do not register that account in the fixture.

5. Replace both paused-operation `vm.expectRevert` calls with `try/catch`
   checks that do not themselves revert on a protocol regression. For
   `buyWhileEmergencyPausedReverts`, set `pausedBuyViolation = true` if
   `buy(...)` succeeds, emits a non-`SalesManager_EmergencyPaused` string
   revert, or reverts with non-string data. Apply the equivalent logic in
   `fulfillFiatWhileEmergencyPausedReverts` using `pausedFiatViolation`.
   Compare string revert reasons with `keccak256(bytes(reason))`.

6. Remove discard-prone `assertEq` and `assertFalse` calls inside these four
   rejected-operation handler actions where their failure would merely revert
   the action and be ignored due to `fail_on_revert = false`. Successful
   forbidden calls are captured by violation flags; regular conservation and
   ghost-state invariants already check persisted accounting/balance
   corruption after a call that unexpectedly succeeds.

7. Add explicit invariant functions in `SalesInvariantTest` asserting that
   every new violation flag remains false:

   ```solidity
       function invariant_zero_allowance_buy_never_succeeds() external view {
           assertFalse(handler.zeroAllowanceBuySucceeded());
       }
   ```

   Add equivalent invariants for the unregistered fiat fulfillment, paused
   buy, and paused fiat flags. Keep these invariants separate so a failing run
   identifies the broken guarantee directly.

8. Format and run the focused invariant suite. Confirm that the handler
   selectors are exercised without handler reverts or discarded actions in
   the normal implementation, and that all new invariants pass.

## 4. Commands to Run

```bash
forge fmt
pnpm format
forge test --match-path test/SalesInvariant.t.sol
forge test
```

## 5. Acceptance Criteria

- [ ] `test/SalesInvariant.t.sol` contains persistent violation state for zero
      allowance buy, unregistered fiat fulfillment, paused buy, and paused
      fiat fulfillment behavior.
- [ ] No rejected-path handler relies on reverting its own transaction after
      an unexpected protocol success.
- [ ] The paused-operation handlers no longer rely on `vm.expectRevert` for a
      condition that must be observable when `fail_on_revert = false`.
- [ ] Paused-operation coverage still rejects wrong revert reasons, not just
      unexpected successful calls.
- [ ] Each violation flag is checked by a dedicated invariant in
      `SalesInvariantTest`.
- [ ] Existing conservation, treasury, buyer-balance, sale-sold, and token-cap
      invariants remain in place.
- [ ] `forge test --match-path test/SalesInvariant.t.sol` passes with the
      corrected handlers and invariants.
- [ ] `forge test` passes after the test-only change.
- [ ] Solidity and repository formatting commands complete without
      introducing unintended generated artifact churn.

## 6. Constraints & Traps

- Both `[profile.default.invariant]` and `[profile.ci.invariant]` in
  `foundry.toml` intentionally set `fail_on_revert = false`; do not change
  that configuration to make this one test appear effective.
- A handler assertion or deliberate handler revert is not durable evidence of
  a bug in this configuration: Foundry can discard the entire action,
  including the bad protocol state.
- Do not remove `targetSelector(...)` or add view getters to the selector
  list; the invariant campaign should continue spending calls on meaningful
  actions.
- Do not remove `CHUNK`, oracle mutation, or the lowered `MAX_SUPPLY`; they
  keep the state machine productive and make the cap boundary reachable.
- Do not modify production `SalesManager` behavior for this task. The issue is
  in the effectiveness of the newly added invariant coverage.
- Do not edit generated `abis/`, `export/`, `out/`, or `cache/` artifacts as
  part of this fix.
