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

## Deploy V2

The generic deploy helper deploys `PolicyRegistry` first, then
`BilateralSettlement`, and writes a public manifest at
`./molttx.manifest.json`.

```bash
npm run deploy:v2 -- \
  --rpc-url https://mainnet.base.org \
  --deployer-private-key 0x... \
  --settlement-owner 0x...
```

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
