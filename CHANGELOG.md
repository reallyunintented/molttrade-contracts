# Changelog

## v0.2.0 - 2026-04-23

- added `cancelNonce()` with sequential nonce-burn semantics
- replaced signed `feeBps` / `feeRecipient` with signed `maxFeeBps`
- resolved settlement fees from live onchain config, bounded by each side's signed cap
- isolated signature recovery in `src/libraries/ECDSA.sol`
- carried forward ownership, pause, policy, and event hygiene landed before PR #6
- verified current `main` with `forge build` and `forge test` (`106/106`)

Notes:
- this is a source release only; canonical deployed addresses are not published yet
- the repo remains early-stage and not publicly audited
