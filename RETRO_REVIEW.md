# Retro Review

This document explains, in a simple step-by-step way, what was done to create
this public contracts repository and how to review it after the fact.

## 1. Goal

The goal was not to publish the full MoltTrade alpha system.

The goal was to publish a small public artifact that proves the on-chain trust
boundary is real.

That means this repo should answer:

- Are there real Solidity contracts?
- Are there real tests?
- Is there a deployment script?
- Is the scope honest?

## 2. Source Of This Repo

This repo was carved out of a larger private monorepo.

Only the contracts-focused slice was copied here.

## 3. What Was Included

These parts were kept:

- `src/`
- `test/`
- `script/DeployBaseMainnet.s.sol`
- `foundry.toml`
- `lib/forge-std/`
- `README.md`
- `.gitignore`
- `LICENSE`
- `RETRO_REVIEW.md`

## 4. What Was Excluded

These larger product surfaces were intentionally left out:

- relayer
- network service
- frontend
- runtime daemon
- alpha session artifacts
- operator tooling
- local environment files

Reason:

This public repo is for legitimacy of the contracts layer, not for exposing the
unfinished hosted system.

## 5. License Decision

This exported contracts repo uses `MPL-2.0`.

Reason:

- it is open source
- it is less aggressive than AGPL for a small contracts repo
- it keeps modifications to covered files under MPL
- it is a good fit for a narrow public code artifact

The larger private monorepo may use a different license posture later. This
export stands on its own.

## 6. Safety And Hygiene Checks

The export was cleaned before Git init:

- no relayer/frontend/runtime code
- no tracked alpha session files
- no local `.env.local` files
- no hardcoded auth tokens
- no hardcoded runtime private keys
- no `.codex` junk file
- no vendored nested `.git` directory inside `lib/forge-std`

Allowed credential reference:

- `DEPLOYER_PRIVATE_KEY` appears only as an environment variable expected by
  the deploy script and README

That is normal and intentional.

## 7. Verification Results

The exported repo was verified independently in `/tmp/molttrade-contracts`.

Commands run:

```bash
forge fmt --check
forge test
```

Result:

- formatting check passed
- Solidity test suite passed
- contract tests passing: `72/72`

## 8. Honest Read Of This Repo

This repo proves:

- the contracts are real
- the tests are real
- the settlement rules are non-trivial
- the deployment path exists

This repo does not prove:

- the full hosted product is public-ready
- the relayer and web stack are public-ready
- the system has had a public audit
- the product is permissionless

That distinction matters.

## 9. How To Review It Yourself

Use this review order:

1. Read `README.md`
2. Read `src/PolicyRegistry.sol`
3. Read `src/BilateralSettlement.sol`
4. Read `test/PolicyRegistry.t.sol`
5. Read `test/BilateralSettlement.t.sol`
6. Run `forge test`
7. Read `script/DeployBaseMainnet.s.sol`

If all of that looks coherent, the repo is doing its job.

## 10. Suggested Public Positioning

Use language like this:

"MoltTrade Contracts is the public on-chain core for the MoltTrade settlement
model. It is not the full hosted product. It is the contracts, tests, and
deployment path."

That framing is accurate and credible.

## 11. Remaining Manual Step

This repo can be pushed to GitHub as:

- repo name: `molttrade-contracts`

Typical push flow:

```bash
git remote add origin git@github.com:<owner>/molttrade-contracts.git
git push -u origin main
```

## 12. Final Teacher-Style Summary

Question:

Did the public export stay focused on the contracts and avoid exposing the
unfinished app stack?

Answer:

Yes.

Question:

Did the exported repo verify independently?

Answer:

Yes, with `forge fmt --check` and `forge test`.

Question:

Is this a fair public proof of legitimacy?

Answer:

Yes. It is small, but it is honest, testable, and real.
