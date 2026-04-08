# MoltTrade Contracts

Public contracts slice for MoltTrade.

This repo is the narrow on-chain trust boundary only:

- `PolicyRegistry.sol`: owner-managed agent policy registry
- `BilateralSettlement.sol`: bilateral EIP-712 settlement contract
- Foundry tests for replay, revoke/pause, fee config, counterparty binding,
  fee-on-transfer handling, and reentrancy
- Base mainnet deployment script

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
  and token compatibility
- tokens move directly between owner wallets

What the contracts do not do:

- custody funds
- run orderbooks
- discover counterparties
- provide hosted relaying or frontend UX

## Status

This is real code, but it is still early-stage infrastructure.

- current Solidity suite: `72/72` passing
- intended first chain: Base mainnet
- intended first usage: narrow invited-alpha style operation
- audit status: not publicly audited

Treat it as a serious contract baseline, not as finished public-network
infrastructure.

## Quick Start

Prerequisites:

- Foundry (`forge`)

Run locally:

```bash
forge fmt --check
forge build
forge test
```

Deploy script:

```bash
forge script script/DeployBaseMainnet.s.sol:DeployBaseMainnet
```

The script expects:

- `DEPLOYER_PRIVATE_KEY`
- optional `SETTLEMENT_OWNER`
- optional `INITIAL_FEE_BPS`
- optional `INITIAL_FEE_RECIPIENT`

## Repo Layout

- `src/`: contracts, interfaces, shared types, token helper library
- `test/`: Foundry tests and token mocks
- `script/`: deployment script
- `lib/forge-std/`: vendored Foundry standard library

## License

This contracts repo is licensed under `MPL-2.0`.

That means modifications to MPL-covered files stay under MPL, while larger works
can remain under different terms.
