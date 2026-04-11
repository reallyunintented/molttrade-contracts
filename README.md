# MoltTrade Contracts

Public contracts slice for MoltTrade.

This repo is the narrow on-chain trust boundary only:

- `PolicyRegistry.sol`: owner-managed agent policy registry
- `BilateralSettlement.sol`: bilateral EIP-712 settlement contract
- Foundry tests for replay, revoke/pause, fee config, counterparty binding,
  per-token sell caps, fee-on-transfer handling, and reentrancy
- Base deployment scripts, including a generic `deploy-v2` helper that writes a
  public `molttx.manifest.json`

This repo does not include the relayer, hosted APIs, frontend, runtime daemon,
or alpha operations tooling. Those are intentionally excluded so the public
artifact stays focused on the part that actually enforces settlement rules.

## Scope

MoltTrade is a non-custodial bilateral settlement model for agent trading.

Core invariant:

`1 owner : 1 active agent : 1 active policy`

What the contracts do:

- owners register a bounded trading policy
- agents sign typed settlement intents
- settlement checks policy validity, replay protection, counterparties, fees,
  sell-token caps, and token compatibility
- tokens move directly between owner wallets

What the contracts do not do:

- custody funds
- run orderbooks
- discover counterparties
- provide hosted relaying or frontend UX

## Policy Model

The current policy shape is V2:

- `allowedSellTokens[]` defines which sell tokens are permitted
- `maxSellAmountsPerToken[]` is index-aligned with `allowedSellTokens[]`
- if a sell token is not listed, the trade is rejected
- if a listed token has cap `0`, that token is allowed but uncapped
- duplicate sell tokens are rejected on policy registration

Caps are enforced in raw token units. The contracts do not do any USD/notional
conversion.

## Status

This is real code, but it is still early-stage infrastructure.

- intended first chain: Base-style deployment environments
- intended first usage: narrow invited-alpha style operation
- audit status: not publicly audited

## Prerequisites

- Foundry (`forge`)
- Node.js 18+
- npm

## Quick Start

```bash
npm install
npm run build
npm test
```

## Deploy Paths

There are two deployment entry points:

- `scripts/deploy-base-mainnet.sh`: opinionated wrapper for Base mainnet deploys
- `scripts/deploy-v2.mjs`: generic deploy helper for Base-style environments

### Base Mainnet

```bash
DEPLOYER_PRIVATE_KEY=0x... ./scripts/deploy-base-mainnet.sh
```

Optional environment variables:

- `SETTLEMENT_OWNER`
- `INITIAL_FEE_BPS`
- `INITIAL_FEE_RECIPIENT`
- `VERIFY=1`
- `ETHERSCAN_API_KEY` when `VERIFY=1`

### Generic Deploy V2

The generic deploy helper deploys `PolicyRegistry` first, then
`BilateralSettlement`, and writes a public manifest at
`./molttx.manifest.json`.

```bash
npm run deploy:v2 -- \
  --rpc-url https://mainnet.base.org \
  --deployer-private-key 0x... \
  --settlement-owner 0x...
```

Run `npm install` first so the `viem` dependency is available.

Optional `--write-frontend-env`, `--write-network-env`, and `--write-relayer-env`
write consumer env snippets into `./generated/`.

Those generated files are intentionally ignored by git. Do not commit deployment
artifacts, generated env files, or private keys.

## Repo Layout

- `src/`: contracts, interfaces, shared types, token helper library
- `test/`: Foundry tests and token mocks
- `script/`: Foundry deployment script
- `scripts/`: shell and Node deployment helpers
- `lib/forge-std/`: vendored Foundry standard library

## License

This contracts repo is licensed under `MPL-2.0`.
