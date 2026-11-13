# BASE GAP — Coinbase Tokenized Stocks (B20) price coverage

Checked: 2026-11-13 (all numbers live-verified, see artifact JSON)

## The gap (as a user action)

A builder on Base can read an onchain price for **12 of 348** Coinbase tokenized stocks.
A holder of AMDc, ARMc, ORCLc or PFEc cannot see what their position is worth onchain:
no Chainlink feed exists for their token, and the issuer's own API publishes no price
for it. Aave's stock-backed lending can only take the 12 covered head names as collateral.

## Counted numbers (verified 2026-11-13)

- Token records: **348** (`GET https://api.coinbase.com/v1/tokenized-stocks`, paginated, no key)
- With published `nav_price` (Chainlink-based NAV): **12** — AAPL AMZN GOOGL META MSFT MSTR
  NVDA SNDK SPCX TSLA CRCL INTC (docs table lists only 10; API is ahead of the docs table)
- Minted (`total_supply` > 0): **72**
- **Minted but unpriced: 60** — the immediate product surface
- Never minted (future listings): **276** — the tail keeps growing
- Chain id verified live: 8453 (`eth_chainId` → 0x2105)
- Onchain cross-check: feed 0x787f13dEa48Db0897CbCDD985de77809D837F988
  `description()` = "Coinbase AAPL", `latestRoundData()` answer = 356.397026 USD at 8
  decimals = API `nav_price` 356.39702621 to the last digit; `totalSupply()` = 6175.40361951
  = API `total_supply` to the last digit. Onchain = API confirmed.

Comparison: Robinhood Chain had 203 tokens / 33 Chainlink feeds (16%) when TailFeed
shipped. Base has 348 / 12 (**3.4%**) with far larger distribution.

## Why the gap is real and not prose

- Base docs claim "Each tokenized equity has a Chainlink feed." The live API and the
  docs' own feed table disagree: 12 of 348. Same pattern Robinhood Chain showed
  (official prose claims full coverage, directory shows a minority).
- Chainlink feeds only exist for the 12 head names. No other onchain price source found.

## The B20 mechanics (verified onchain, all read-only)

- Tokens live at `0xb2…` precompile addresses; `eth_getCode` returns `0xef` (one byte).
  Every standard tool that checks "is this a contract" or verifies source behaves wrong.
- ERC-20 calls work natively: `symbol`, `name`, `decimals`, `totalSupply`.
- `uiMultiplier()` (0xa60bf13d) returns WAD-scaled (1e18) redemption ratio. AAPL = 1e18 = 1.0.
- `balanceOfUI(address)` applies the multiplier — same selector family as Robinhood Chain.
- Multiplier updates are scheduled (ERC-8056, `updateUIMultiplier`) with onchain notice;
  instant variant deprecated. Same standard family as Robinhood Chain — the position math
  from `tools/rh_position_check.py` ports directly.
- Chainlink's feed reads the multiplier + pause flag from Coinbase's onchain oracle
  registry; feeds freeze during corporate actions and hold last value off-hours.
  `nav_price` staleness is the reader's job, same as TailFeed.

## Competitor inventory (registries checked 2026-11-13)

- npm: `base-std`, `@base/base-std`, `b20`, `b20-sdk`, `coinbase-tokenized-stocks`,
  `base-tokenized-stocks` — all NOT FOUND. `tailfeed` (ours) not yet published.
- PyPI: nothing for Base tokenized stocks. (`robinhood-chain` exists for the other chain.)
- `base/base-std` on GitHub = official Solidity interfaces + mocks for Base precompiles
  (forge install). Interfaces only: no data product, no JS/Python SDK, no feeds.
  Developer-layer contracts taken; data layer open.
- Chainlink: 12/348 head feeds. The incumbent, optimizes for head names.
- Coinbase Tokenized Stocks API: offchain reference for the 12; no onchain publication,
  no wallet endpoints, no billing rail.

## Demand evidence (honest)

- Strong institutional: Base's own Request for Builders (Sep 1, 2026) calls for
  neobrokerages, personalized indexes, yield/credit products on tokenized stocks — all of
  which need per-token reference prices. Aave stock-backed lending live on Base since
  Sep 29. Base Batches 004 cohort names customers: Greek, Grow, Tribeca, Renn, BitRepo.
- Direct user pull ("where is my AMDc price"): unverified. Score demand 3.5/5, not 5/5.
- Paid-incumbent proof on the sister chain: RobinhoodRPC ($50–200/mo) for the same
  asset class on Robinhood Chain. On Base no paid data provider found yet.

## What we will NOT do

No deploy, no signing, no token, no public post yet. No swap/mint/lend/credit product on
these assets (issuer restricts US persons; read-only price layer only). No mainnet until
the owner has used the thing. Use the issuer's own naming: "Coinbase tokenized stocks
(B20)" — never rebrand it.

## The pick

Port the TailFeed flywheel to Base as two repos under slugelife-ux:

1. **b20-feeds** — Foundry contracts: AggregatorV3-compatible feeds for the unpriced
   tail, deviation-gated batch pusher (one tx for all moved feeds), multiplier read
   from the token itself, price from a disclosed quote source; health checker
   (b20_price_check.py) comparing every feed to live quotes; static status page.
   E2E on an anvil fork of Base mainnet (B20 precompiles live there).
2. **b20-kit** — zero-dependency npm SDK (+ Python): B20 reads, multiplier-correct
   portfolio, balanceOfUI share math, B20Created-based token discovery, 0xef-code-safe
   address handling. Free forever; the adoption magnet that pulls developers onto the feeds.

TailFeed (Robinhood Chain) continues its own track to Stage D in parallel.
