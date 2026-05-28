---
status: accepted
---

# Defer Chainlink L2 sequencer-uptime check (Polygon PoS launch)

## Context

`SalesManager._getTokenUsdPrice1e8` reads Chainlink price feeds to convert USD share
prices into payment-token amounts. On rollup L2s (Arbitrum, Optimism, Base, Metis,
Scroll, zkSync Era) Chainlink publishes a **Sequencer Uptime Feed**: if the sequencer
was down (or within its grace period after recovery), the price feed may be stale even
though `updatedAt` looks recent, and integrators are expected to read the uptime feed
and revert.

CoinDistrict launches on **Polygon PoS**, which is a sidechain with its own validator
set — there is **no centralized sequencer and no Chainlink Sequencer Uptime Feed** to
read. A sequencer check would be dead, unreachable code on this chain.

## Decision

Do **not** implement a sequencer-uptime check for the Polygon PoS launch. Rely on the
existing `updatedAt` staleness guard (`block.timestamp - updatedAt <= maxOracleDelaySeconds`)
as the freshness defense.

## Consequences / revisit trigger

This assumption is baked into the oracle read path. **Before deploying to any rollup L2**
(Arbitrum / Optimism / Base / Metis / Scroll / zkSync Era), this decision must be
revisited: add a per-deployment, gov-configurable sequencer-uptime-feed address; when set,
`_getTokenUsdPrice1e8` must read it, require the sequencer to be up, and enforce the
post-recovery grace period before trusting any price. Keep it optional (`address(0)` = skip)
so the same bytecode stays valid on Polygon PoS.

Because `SalesManager` is a UUPS proxy, this is addable later via upgrade (new storage:
append after `_sales` or shrink `_gap[50]`).
