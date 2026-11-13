# b20-feeds

Onchain price feeds for the Coinbase tokenized stocks (B20) on Base that Chainlink doesn't cover — AggregatorV3-compatible, so a Chainlink consumer swaps one address and changes nothing else.

**348 Coinbase tokenized stocks trade on Base. The issuer's API publishes a Chainlink-based NAV for 12. The other 336 — including 60 already minted with real supply (AMD, ARM, ORCL, PFE, RIVN, DJT...) — have no contract-readable price at all.**

Numbers live-verified 2026-11-13 against the issuer's API and Base mainnet (chain 8453, verified via `eth_chainId`). Full record: `RESEARCH.md`.

## Status

**Research complete. Build not started.** This repo is the landing zone: the gap is counted, the design is decided, the plan is below. Contracts, pusher, checker, and status site get built here.

## What gets built

- `FeedRegistry` + per-token feed proxies on Base, AggregatorV3 interface (`latestRoundData()`, 8 decimals) — read them exactly like a Chainlink feed.
- A deviation-gated batch pusher: one transaction updates every feed that moved ≥ 0.5% (or on heartbeat). This is what makes the tail affordable — incumbents optimize for head names; one batch tx covers the whole tail.
- The multiplier is read straight from the token onchain (`uiMultiplier()`, WAD-scaled 1e18, ERC-8056 scheduled updates) — the same standard Robinhood Chain's stock tokens use, so the multiplier math is a port of a proven implementation, not a new design.
- Price derivation: underlying equity reference price × current multiplier, matching the issuer's own documented formula. The quote source is disclosed in the README and the feed's `description()`.
- `tools/b20_price_check.py` — health checker comparing every feed (ours and Chainlink's) against live quotes. On the sister chain this checker already caught a Chainlink feed sitting 0.40% off with a fresh heartbeat.
- A static status page that reads the chain from the visitor's browser.

## Build plan

- **Stage A:** Foundry contracts + unit/invariant tests; B20 behavior tested against Base's own toolchain: `base-anvil`/`base-forge` (Base's Foundry fork) runs the B20 precompiles in-process, so multiplier reads are tested against the real precompile behavior, not a mock. Verified 2026-11-13: stock anvil forking Base mainnet cannot execute B20 precompile calls (`OpcodeNotFound`); reads against the live public RPC work and are part of e2e. Quote → multiplier → push → readback equality proven against real mainnet state via RPC + local precompile tests.
- **Stage B:** testnet deployment (Base Sepolia) + cron pusher, stable-days gate.
- **Stage C:** publish repo + SDK live.
- **Stage D (owner-gated):** mainnet dry-run package (top tail symbols, gas math, timelock/multisig proposal) → owner approves and signs → pusher on its own VPS → 30 stable days.
- **Stage E:** paid tiers (alerts, history API, feed subscriptions). Reads stay free forever. Optional delivery rail: x402 per-call billing — 99.2% of x402 endpoints settle on Base (ChainReport, 2026-11-12), and no tokenized-equity price endpoint exists on x402 yet; demand is thin (738 endpoints with 10+ payers of 33,901), so it's a cheap add-on, not the business.

## Who needs this today

- Lending protocols on Base: stock-backed lending is live against the 12 covered head names only. The 60 minted-but-unpriced tokens can't be collateral until a feed exists.
- Base's own Request for Builders (Sep 2026) asks for neobrokerages, personalized indexes, and credit products on tokenized stocks — every one of those needs per-token reference prices.
- The issuer's API is offchain, paginated reference data with no wallet endpoints and no onchain publication; it prices 12 of 348.

## Rules kept

- Read-only price layer. No swap, mint, lend, or trading product on these assets.
- "Coinbase tokenized stocks (B20)" — the issuer's own naming, always.
- Source verified for every deployed contract. No token, no hidden mint, no upgrade path. One admin power, stated plainly: the pusher address.
- Staleness is the reader's job (as with Chainlink): check `block.timestamp - updatedAt`. Feeds hold last value when US markets are closed — by design, matching the covered feeds' behavior.
- Not affiliated with Coinbase or Base.

## Repository layout (planned)

```
contracts/   Foundry: FeedRegistry, feed proxy, tests, fork e2e scripts
pusher/      deviation-gated batch pusher (cron)
tools/       b20_price_check.py, position verifier
web/         static status site
data/        gap counts and verification artifacts
```

## License

MIT
