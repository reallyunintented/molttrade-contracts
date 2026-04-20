# Post-Hardening Follow-Ups Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship the five follow-up items flagged during review of PR #2 (merged 2026-04-11): four small hygiene fixes in one PR, then Pausable as a second PR.

**Architecture:** All changes stay inside the two existing contracts (`BilateralSettlement`, `PolicyRegistry`) and their tests. No new files outside the existing layout, no new dependencies, no OpenZeppelin imports. Pausable follows the same minimalist pattern already used by the local `nonReentrant` modifier.

**Tech Stack:** Solidity 0.8.24, Foundry (`forge test`, `forge build`), existing test harness under `test/`.

**Baseline:** 81 tests passing on `main` at `013ae2e`. After this plan: Phase 1 adds 2 tests (83 total), Phase 2 adds ~9 tests (~92 total).

---

## Phase 1 — Hygiene PR

Branch: `hygiene/rotate-test-dead-code-cancel-event-revoke-nonce`

Four independent items bundled as one PR because each is a 1–5 LOC change with its own one-line justification.

---

### Task 1: Rotate-pending-owner test

Asserts the recovery path: if `transferOwnership(A)` is called and then the owner changes their mind and calls `transferOwnership(B)`, A must not be able to accept and B must. The code already supports this — we're locking it down with a test.

**Files:**
- Modify: `test/BilateralSettlement.t.sol` (add after `test_transferOwnership_cancelWithZeroAddress`)

**Step 1: Add the test**

```solidity
function test_transferOwnership_rotatesPendingOwner() public {
    address first = makeAddr("first");
    address second = makeAddr("second");

    settlement.transferOwnership(first);
    assertEq(settlement.pendingOwner(), first);

    settlement.transferOwnership(second);
    assertEq(settlement.pendingOwner(), second);

    vm.prank(first);
    vm.expectRevert(BilateralSettlement.NotPendingOwner.selector);
    settlement.acceptOwnership();

    vm.prank(second);
    settlement.acceptOwnership();
    assertEq(settlement.owner(), second);
    assertEq(settlement.pendingOwner(), address(0));
}
```

**Step 2: Run**

```
forge test --match-test test_transferOwnership_rotatesPendingOwner -vv
```
Expected: **PASS** (no implementation change — asserting existing behavior).

---

### Task 2: Remove dead `ZeroOwner` check in `acceptOwnership`

`msg.sender != pending` already rejects the `pending == address(0)` case, because `msg.sender` is never `address(0)` in any EVM transaction. The second check is unreachable and clutters the function.

**Files:**
- Modify: `src/BilateralSettlement.sol:90-100`

**Step 1: Replace the function body**

Before:
```solidity
function acceptOwnership() external {
    address pending = pendingOwner;
    if (msg.sender != pending) revert NotPendingOwner();
    if (pending == address(0)) revert ZeroOwner();

    address previousOwner = owner;
    owner = pending;
    pendingOwner = address(0);

    emit OwnershipTransferred(previousOwner, pending);
}
```

After:
```solidity
function acceptOwnership() external {
    address pending = pendingOwner;
    // `msg.sender != pending` already rejects pending == address(0),
    // since msg.sender cannot be address(0) in any EVM transaction.
    if (msg.sender != pending) revert NotPendingOwner();

    address previousOwner = owner;
    owner = pending;
    pendingOwner = address(0);

    emit OwnershipTransferred(previousOwner, pending);
}
```

**Step 2: Run full suite**

```
forge test
```
Expected: **82 passed / 0 failed** (81 pre-existing + Task 1).

---

### Task 3: Dedicated `OwnershipTransferCanceled` event

Off-chain indexers otherwise see `OwnershipTransferStarted(owner, 0x0)` on cancel and have to infer the semantic. A dedicated event removes the ambiguity.

**Files:**
- Modify: `src/interfaces/IBilateralSettlement.sol` (add event declaration after `OwnershipTransferStarted`)
- Modify: `src/BilateralSettlement.sol:83-86` (branch the emit)
- Modify: `test/BilateralSettlement.t.sol` (add a new test)

Note: the existing test file has no `vm.expectEmit` usage (state-only assertions). Task 3 introduces the pattern for one new test — justified because the whole point is to verify which event fires.

**Step 1: Add the event to the interface**

`src/interfaces/IBilateralSettlement.sol` — add the new line:
```solidity
event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
event OwnershipTransferCanceled(address indexed previousPendingOwner);
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

**Step 2: Write the failing test**

Add to `test/BilateralSettlement.t.sol`, near the other cancel test:
```solidity
function test_transferOwnership_cancelEmitsCanceledEvent() public {
    address newOwner = makeAddr("newOwner");
    settlement.transferOwnership(newOwner);

    vm.expectEmit(true, false, false, false, address(settlement));
    emit IBilateralSettlement.OwnershipTransferCanceled(newOwner);
    settlement.transferOwnership(address(0));
}
```

Run:
```
forge test --match-test test_transferOwnership_cancelEmitsCanceledEvent -vv
```
Expected: **FAIL** (event declared but not emitted yet).

**Step 3: Branch the emit**

`src/BilateralSettlement.sol:83-86` — replace:
```solidity
function transferOwnership(address newOwner) external onlyOwner {
    pendingOwner = newOwner;
    emit OwnershipTransferStarted(owner, newOwner);
}
```

With:
```solidity
function transferOwnership(address newOwner) external onlyOwner {
    if (newOwner == address(0)) {
        emit OwnershipTransferCanceled(pendingOwner);
    } else {
        emit OwnershipTransferStarted(owner, newOwner);
    }
    pendingOwner = newOwner;
}
```

**Step 4: Run**

```
forge test
```
Expected: **83 passed / 0 failed**.

---

### Task 4: `revokePolicy` policy-nonce bump

`pausePolicy`, `unpausePolicy`, and `setPolicy` all bump `policyNonce`. `revokePolicy` does not. Defense-in-depth: any future code path that reads policy state directly by nonce should not silently consume a stale nonce value from a revoked policy. Mirrors the existing pattern.

**Files:**
- Modify: `src/PolicyRegistry.sol:54-60`
- Modify: `test/PolicyRegistry.t.sol`

**Step 1: Write the failing test**

Add to `test/PolicyRegistry.t.sol` near the existing revokePolicy tests:
```solidity
function test_revokePolicy_bumpsPolicyNonce() public {
    vm.prank(owner);
    registry.setPolicy(_defaultConfig(), _defaultAddrs());
    uint256 nonceBefore = registry.policyNonce(owner);

    vm.prank(owner);
    registry.revokePolicy();

    assertEq(registry.policyNonce(owner), nonceBefore + 1);
}
```

Run:
```
forge test --match-test test_revokePolicy_bumpsPolicyNonce -vv
```
Expected: **FAIL** (nonce unchanged).

**Step 2: Add the bump**

`src/PolicyRegistry.sol:54-60` — replace:
```solidity
function revokePolicy() external {
    StoredPolicy storage p = _policies[msg.sender];
    if (!p.exists) revert NoPolicySet();
    if (p.isRevoked) revert AlreadyRevoked();
    p.isRevoked = true;
    emit PolicyRevoked(msg.sender);
}
```

With:
```solidity
function revokePolicy() external {
    StoredPolicy storage p = _policies[msg.sender];
    if (!p.exists) revert NoPolicySet();
    if (p.isRevoked) revert AlreadyRevoked();
    policyNonce[msg.sender]++;
    p.isRevoked = true;
    emit PolicyRevoked(msg.sender);
}
```

**Step 3: Run**

```
forge test
```
Expected: **84 passed / 0 failed** (81 + Task 1 + Task 3 + Task 4).

---

### Task 5: Commit Phase 1 and open PR

```bash
git checkout -b hygiene/rotate-test-dead-code-cancel-event-revoke-nonce
git add src/BilateralSettlement.sol \
    src/interfaces/IBilateralSettlement.sol \
    src/PolicyRegistry.sol \
    test/BilateralSettlement.t.sol \
    test/PolicyRegistry.t.sol
git commit -m "hygiene: rotate test, dead-code cleanup, cancel event, revoke nonce"
git push -u origin hygiene/rotate-test-dead-code-cancel-event-revoke-nonce
```

```bash
gh pr create \
    --title "Hygiene: rotate test, dead-code cleanup, cancel event, revoke nonce" \
    --body "$(cat <<'EOF'
## Summary

Four small follow-ups surfaced during review of #2. All independent, bundled because each is 1–5 LOC.

### 1. `test_transferOwnership_rotatesPendingOwner`

Locks down the pending-owner recovery path: `transferOwnership(A)` then `transferOwnership(B)` must rotate A out so only B can accept. Code already supported this; now asserted.

### 2. Remove dead `ZeroOwner` check in `acceptOwnership`

`msg.sender != pending` already rejects `pending == address(0)`, since `msg.sender` is never `address(0)`. Deleted the unreachable second check and left a one-line comment explaining why.

### 3. Dedicated `OwnershipTransferCanceled` event

`transferOwnership(address(0))` previously emitted `OwnershipTransferStarted(owner, 0x0)`, which off-chain indexers would have to interpret. Added `OwnershipTransferCanceled(previousPendingOwner)` and branch the emit in `transferOwnership`. Additive — non-cancel transfers still emit `OwnershipTransferStarted`, existing indexers keep working.

### 4. `revokePolicy` policy-nonce bump

`pausePolicy`, `unpausePolicy`, and `setPolicy` all bump `policyNonce`. `revokePolicy` didn't. Defense-in-depth: bumping on revoke means no future code path can silently consume a stale nonce for a revoked policy.

## Tests

```
PolicyRegistry:      36 passed / 0 failed  (was 35)
BilateralSettlement: 48 passed / 0 failed  (was 46)
Total:               84 passed / 0 failed  (was 81)
```

## Breaking change

None. The new event is additive; `OwnershipTransferStarted` is still emitted on non-cancel transfers.

## Test plan

- [x] `forge build`
- [x] `forge test` — 84/84
EOF
)"
```

Expected: PR opens cleanly; CI (if any) runs `forge test` and passes.

---

## Phase 2 — Pausable PR

Branch: `feat/pausable-settlement`

Bigger change with its own design surface. Separate PR for easier review.

---

### Task 6: Design notes (read before Task 7)

- **Pattern:** minimalist, same style as existing `nonReentrant` modifier. No OpenZeppelin import.
- **Access control:** `onlyOwner` for `pause()`/`unpause()`.
- **Blast radius:** only `settle` is gated by `whenNotPaused`. Fee admin (`setFee`) and ownership transfer stay callable during a pause — the owner must still be able to rotate/fix things mid-incident.
- **Storage byproduct:** move `pendingOwner` from `L32` (between `owner` and `feeRecipient`) to the end of the state block, and add `bool public paused;` next to it. Non-upgradeable contract, so this only matters for future fresh deploys, but it's the right time to tidy the layout since we're adding another bool.
- **Error names:** `Paused`, `AlreadyPaused`, `NotPaused`. `PolicyRegistry` already has `AlreadyPaused`/`NotPaused` errors, but those are scoped to that contract — no collision.

### Task 7: Write failing tests

Add to `test/BilateralSettlement.t.sol`:

```solidity
function test_pause_onlyOwner() public {
    vm.prank(makeAddr("stranger"));
    vm.expectRevert(BilateralSettlement.NotOwner.selector);
    settlement.pause();
}

function test_pause_setsPausedFlag() public {
    settlement.pause();
    assertTrue(settlement.paused());
}

function test_pause_alreadyPaused_reverts() public {
    settlement.pause();
    vm.expectRevert(BilateralSettlement.AlreadyPaused.selector);
    settlement.pause();
}

function test_unpause_onlyOwner() public {
    settlement.pause();
    vm.prank(makeAddr("stranger"));
    vm.expectRevert(BilateralSettlement.NotOwner.selector);
    settlement.unpause();
}

function test_unpause_clearsFlag() public {
    settlement.pause();
    settlement.unpause();
    assertFalse(settlement.paused());
}

function test_unpause_whenNotPaused_reverts() public {
    vm.expectRevert(BilateralSettlement.NotPaused.selector);
    settlement.unpause();
}

function test_setFee_stillCallableWhilePaused() public {
    settlement.pause();
    // Fee admin must stay callable during incidents.
    settlement.setFee(20, makeAddr("feeRecipient"));
    assertEq(settlement.feeBps(), 20);
}

function test_transferOwnership_stillCallableWhilePaused() public {
    address newOwner = makeAddr("newOwner");
    settlement.pause();
    settlement.transferOwnership(newOwner);
    assertEq(settlement.pendingOwner(), newOwner);
}

function test_settle_revertsWhenPaused() public {
    // Build a settlement intent pair using the same helper pattern as
    // `test_settle_transfersTokens`. After pause, the call must revert.
    // [Reuse existing _signedIntent / _buildPair helpers in this file.]
    settlement.pause();
    vm.expectRevert(BilateralSettlement.Paused.selector);
    settlement.settle(/* intentA, intentB, sigA, sigB from helper */);
}
```

Run:
```
forge test --match-contract BilateralSettlementTest
```
Expected: **9 new failures** — `pause()`, `unpause()`, `paused()`, and the `Paused` error don't exist yet.

### Task 8: Implement Pausable

**Files:**
- Modify: `src/BilateralSettlement.sol`
- Modify: `src/interfaces/IBilateralSettlement.sol`

**Step 1: Update storage layout**

At `src/BilateralSettlement.sol:29-34`, remove the existing declaration of `pendingOwner` from between `owner` and `feeRecipient` and add `paused` + `pendingOwner` at the **end** of the state block (after `feeBps`):

```solidity
mapping(address => uint256) public nonces;

address public owner;
address public feeRecipient;
uint256 public feeBps;

// Ownable2Step + Pausable additions — kept at the end of the state
// block so future fresh deploys don't pay for mid-struct insertions.
address public pendingOwner;
bool public paused;
```

**Step 2: Add errors and events**

Next to the existing `error` block (around L37-48):
```solidity
error Paused();
error AlreadyPaused();
error NotPaused();
```

Next to the existing `event` block:
```solidity
event ContractPaused(address indexed caller);
event ContractUnpaused(address indexed caller);
```

(Name them `ContractPaused`/`ContractUnpaused` rather than `Paused`/`Unpaused` to avoid collision with the `Paused` error selector in this contract.)

**Step 3: Add the modifier**

Near the existing `nonReentrant` modifier (around L50-55):
```solidity
modifier whenNotPaused() {
    if (paused) revert Paused();
    _;
}
```

**Step 4: Add `pause` and `unpause`**

Near `setFee`:
```solidity
function pause() external onlyOwner {
    if (paused) revert AlreadyPaused();
    paused = true;
    emit ContractPaused(msg.sender);
}

function unpause() external onlyOwner {
    if (!paused) revert NotPaused();
    paused = false;
    emit ContractUnpaused(msg.sender);
}
```

**Step 5: Apply `whenNotPaused` to `settle`**

At `src/BilateralSettlement.sol:149`, change:
```solidity
) external nonReentrant {
```
To:
```solidity
) external nonReentrant whenNotPaused {
```

**Step 6: Update the interface**

`src/interfaces/IBilateralSettlement.sol` — add events and function declarations:
```solidity
event ContractPaused(address indexed caller);
event ContractUnpaused(address indexed caller);

function paused() external view returns (bool);
function pause() external;
function unpause() external;
```

**Step 7: Run**

```
forge test
```
Expected: **~93 passed / 0 failed** (84 + 9 new).

### Task 9: Commit Phase 2 and open PR

```bash
git checkout main && git pull
git checkout -b feat/pausable-settlement
git add src/BilateralSettlement.sol \
    src/interfaces/IBilateralSettlement.sol \
    test/BilateralSettlement.t.sol
git commit -m "feat: Pausable on BilateralSettlement (owner-gated, gates settle only)"
git push -u origin feat/pausable-settlement
```

```bash
gh pr create \
    --title "Add Pausable to BilateralSettlement" \
    --body "$(cat <<'EOF'
## Summary

Adds an owner-gated circuit breaker to `BilateralSettlement`. Only `settle` is blocked while paused — fee admin and ownership transfer stay callable so the owner can act during an incident.

## Design

- Minimalist Pausable in the same style as the existing `nonReentrant` modifier. No OpenZeppelin import.
- `pause()` / `unpause()` are `onlyOwner` and revert on redundant transitions (`AlreadyPaused` / `NotPaused`).
- `whenNotPaused` modifier applied only to `settle`. `setFee`, `transferOwnership`, `acceptOwnership`, and `revokePolicy`-side operations stay callable.
- Storage layout: `pendingOwner` moved to the end of the state block alongside the new `paused` bool. Non-upgradeable contract, so this only affects future fresh deploys — no migration required for anything currently deployed.

## Events

Using `ContractPaused` / `ContractUnpaused` (not `Paused` / `Unpaused`) to avoid a name collision with the `Paused` error selector inside the same contract.

## Tests

- `test_pause_onlyOwner`
- `test_pause_setsPausedFlag`
- `test_pause_alreadyPaused_reverts`
- `test_unpause_onlyOwner`
- `test_unpause_clearsFlag`
- `test_unpause_whenNotPaused_reverts`
- `test_setFee_stillCallableWhilePaused`
- `test_transferOwnership_stillCallableWhilePaused`
- `test_settle_revertsWhenPaused`

Total: ~93 tests passing (was 84 after the hygiene PR).

## Test plan

- [x] `forge build`
- [x] `forge test`
- [ ] Manual sanity check on a local anvil: deploy, pause, attempt settle → reverts; unpause, settle → succeeds.
EOF
)"
```

---

## Out of scope (deferred, tracked)

From PR #2's own out-of-scope list, not scheduled in this plan:

- **Admin-DoS via `setFee`** — mitigation is a timelock, not a bug fix. Needs separate design discussion (threshold, delay, who queues).
- **ERC-1271 smart-contract-wallet agents** — needs signature replay analysis and intent-format discussion.

Leaving these tracked. Open separate issues or revisit if the threat model shifts.
