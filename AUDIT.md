# AUDIT.md — luv-locker

Self-audit. Findings inherited from the SHAMBA LUV `LUVLocker` review of 2026-08-03 and
re-decided here. Self-audited by compiling and executing, not by reading — which is not a
substitute for an independent audit, and this document is not one.

---

## 1. Inherited findings

| ID | Severity | Original finding | Disposition here |
|---|---|---|---|
| A1 | Medium | Owner could extend any depositor's lock repeatedly | **Removed the owner.** `extend_lock` takes no user argument — it acts only on `msg.sender` |
| A2 | Low | Asset locks not extendable | **Out of scope.** Generic asset locks moved to `../liq-locker`, where they are extendable |
| A3 | Low/UX | Locks bound to funder | **Out of scope**, same reason. Reflection positions are inherently per-depositor |
| A4 | Info | No incident brake | **Not applicable.** No owner to operate one. See §3 |
| A5 | Info | Single-step ownership | **Not applicable.** No ownership |

Additionally, `setLockDuration` is gone: `LOCK_DURATION` is immutable. Changing the default
lock length for future deposits is a small power, but it is still a power, and removing it
costs only a redeployment.

**Regression test:** `test_A1_ExtendActsOnlyOnTheCallersOwnLock`.

---

## 2. The structural change, and the class of bug it removes

The live vault runs the reflection pool **and** holds generic ERC-20 timelocks in one
contract. Consequences, all visible in the original source:

- Reward balance had to be `balance − principal − totalAssetLocked[LUV]`, a three-term
  subtraction that is wrong if any term is missed.
- `if (token == LUV)` appeared in `lockAsset`, `withdrawAsset`, `rescue`, `_surplus`, and
  the accrue/sync calls around each — every one of which had to remember to call `_accrue`
  before and `_syncRewardBalance` after. Each case reads correctly in isolation. That is
  precisely why the class survives review.
- `rescue` had to compute a different surplus for LUV than for every other token.

Splitting the module deletes all of it. Reward balance here is `balance − total_principal`,
with no token identity check anywhere in the file, because the contract holds exactly one
token. This is BANKON's standing rule that folder boundaries are load-bearing, applied to
a case where collapsing them was actively generating bug surface.

---

## 2a. Findings from the 2026-08-05 review (parallel LUVLocker deep-audit) — FIXED here

The 2026-08-03 audit this module was built from missed two related defects in the
reflection-credit path; a parallel deep audit of the live `LUVLocker` on 2026-08-05 found
them, and they were present in this module verbatim because the reward accounting was
carried across intact. Both are now fixed and regression-tested with a mock that reflects
**during** a transfer (the stock `mock_luv` reflects only via a separate `reflect()` call,
so the original suite structurally could not see either bug).

| ID | Severity | Finding | Fix |
|---|---|---|---|
| C-1 | **High→fixed** | `deposit` credited the measured balance delta as principal. LUV rebases UP during a transfer (it runs `_processFees` at the top of `_transfer`), so the delta can exceed `amount` by the vault's share of a reflection that flushes mid-deposit. A dust deposit timed to a fee-flush absorbed a reflection that belonged to existing depositors as the depositor's own principal — steal-the-yield. | Cap `received` at `amount`; the surplus stays in the reward balance and `_accrue()` distributes it to the index pro-rata before the new depositor's debt is struck. `luv_locker.sol:160-185`. |
| M-3 | **Med→fixed** | Every mutator ended with a bare resync of `last_reward_balance`. A reflection that flushed during the vault's own OUTGOING transfers (withdraw / harvest / auto-pay) was overwritten by that resync and orphaned — permanently unclaimable by anyone. | Replaced every resync with `_accrue()`, which distributes any mid-call growth to the index and is identical to a resync when nothing grew. The bare `_sync()` helper is removed. |

**Regression tests:** `test/luv_locker_reflect_on_transfer.t.sol` —
`test_ReflectionDuringDepositGoesToTheIndexNotTheDepositor` (C-1),
`test_ReflectionDuringWithdrawIsNotOrphaned` (M-3). Both fail against the pre-fix source.

Note this makes the §5 "measured-delta credits the fee correctly" property stronger, not
weaker: the credit is now `min(delta, amount)`, which is correct for a fee-DOWN token
(delta ≤ amount, so the cap is a no-op) AND a rebase-UP token (delta > amount, cap binds).

## 2b. Found and fixed here (2026-08-13)

**D-1 (Low) — compound mode could over-credit principal by dust, stranding the last wei.**

*Found by:* the stateful invariant fuzzer added for §7, which broke
`balanceOf(vault) >= total_principal` by exactly one wei after a sequence involving
compound mode.

*Mechanism.* In compound mode `_settle` moves `pending` out of the reward side and into
principal. `pending` comes from the index, and the index is a scaled approximation
accumulated across changing values of `total_principal`; it can value a user's share one
wei above the balance actually backing it. Writing that wei into `total_principal` made the
vault owe more principal than it held.

*Consequence, measured rather than assumed.* Not theft and not a griefing lever — an
attacker cannot inflate it. But it is not cosmetic either: with the vault one wei short,
the **last** depositor's `withdraw(principal)` **reverts** on the token transfer. In the
reproduction the final depositor held 3 wei of principal against a 2 wei balance;
`withdraw(3)` reverted, `withdraw(2)` succeeded, and 1 wei of principal was left
permanently unredeemable — there is no owner and no rescue, so `total_principal` could
never return to zero. A depositor seeing their withdrawal fail has no way to know they
should ask for one wei less.

*Fix.* Cap compounding at what the reward side actually holds:

```solidity
uint256 avail = _reward_balance();
if (pending > avail) pending = avail;
```

which enforces `balance >= total_principal` directly. The capped remainder is at most dust
and stays on the reward side, where it benefits every depositor instead of one.

*Regression cover.* `invariant_BalanceCoversAllPrincipal` (32,768 calls) plus
`test_D1_CompoundCanOvercreditPrincipalByDust` and
`test_D1_ShortfallCannotStrandAWithdrawal`, which drives the exact failing sequence and
then exits every depositor in the worst order.

---

## 3. Properties verified to hold

| Area | Verdict | Test |
|---|---|---|
| Reflection accounting | Staking index at 1e27; pro-rata across depositors | `test_TwoDepositorsSplitReflectionsProRata` |
| No retroactive yield | A late depositor earns nothing from earlier reflections | `test_LateDepositorEarnsNothingFromEarlierReflections` |
| Under-reserve payouts | `_pay_accrued` caps at the real reward balance — harvests starve, never over-pay | `test_HarvestNeverPaysOutOfPrincipal` |
| Solvency | Balance never falls below `total_principal` under arbitrary deposit/reflect sequences | `testFuzz_BalanceAlwaysCoversPrincipal` |
| Promises are backed | `pending_rewards` never exceeds `reward_balance` | `testFuzz_PendingRewardsNeverExceedRewardBalance` |
| Fee-on-transfer safety | Deposits credit the measured delta; the fee is not miscounted as interest | `test_DepositCreditsMeasuredDeltaUnderTransferFee` |
| Principal containment | LUV can never be swept by anyone, including the deployer | `test_LuvCanNeverBeSwept` |
| Foreign token recovery | Permissionless, to an immutable sink, caller gets nothing | `test_ForeignTokenSweepsToTheImmutableSink` |
| Same-block games | Block lock holds even after the time lock passes | `test_BlockLockHoldsEvenAfterTimeLockPasses` |
| Compounding | Folds into principal, and does **not** reset the lock clock | `test_CompoundingDoesNotResetTheLockClock` |
| Extend-only | Never shortens | `test_ExtendLockNeverShortens` |
| Reflection during deposit | Goes to the index, never to the last depositor's principal (C-1) | `test_ReflectionDuringDepositGoesToTheIndexNotTheDepositor` |
| Reflection during payout | Distributed to remaining depositors, not orphaned (M-3) | `test_ReflectionDuringWithdrawIsNotOrphaned` |

### Time properties (`test/luv_locker_time.t.sol`, 9 tests)

| Area | Verdict | Test |
|---|---|---|
| Maturity boundary | Reverts at unlock−1s; opens exactly at unlock | `test_WithdrawRevertsOneSecondBeforeMaturity`, `test_WithdrawSucceedsExactlyAtMaturity` |
| Extend across time | A mid-term extension holds past the original maturity to the new one | `test_ExtendPartwayThroughPushesMaturityOut` |
| Extend-only over time | Cannot shorten even after time elapses | `test_ExtendCannotShortenEvenAfterTimePasses` |
| Ten-year horizon | Extend caps at now+MAX; a full-decade lock matures and withdraws end to end | `test_ExtendRejectsBeyondTenYearHorizon`, `test_TenYearMaxHorizonLockAndWithdraw` |
| Re-lock on deposit | A top-up re-locks the ENTIRE principal to a fresh full term | `test_DepositRelocksEntirePrincipalOverTime` |
| Compound over years | Repeated compounding across years never moves the unlock time | `test_CompoundingOverYearsDoesNotResetClock` |
| Block lock vs time lock | Block lock still holds when time alone is satisfied | `test_BlockLockStillHoldsWhenTimeIsSatisfied` |

---

## 4. Documented behaviours — intentional, and stated because they surprise people

**A deposit re-locks the entire principal.** Any new deposit pushes *all* of the
depositor's principal out to `now + LOCK_DURATION`, not just the new amount. The original
audit flagged this as intentional-but-unstated. It is now stated in the contract, the
README, and `test_DepositRelocksTheEntirePrincipal`.

**Interest accrues only while the vault is reflection-included.** This is a setting on the
LUV token, not in this repository. If the token excludes this contract, interest silently
stops and **nothing here can detect it**. It is an operational invariant to be checked
on-chain, not a code property.

**Index dust.** Floor division in the reward index leaves dust in the vault, which
re-enters the reward balance on the next accrual. Standard staking-index behaviour,
bounded and benign.

**Compound mode reports zero pending.** In `lock_interest` mode, `pending_rewards` returns
only the already-accrued claimable balance, because pending interest is destined to become
principal rather than a claim. Not a bug; the alternative would misreport a claim that
cannot be made.

---

## 5. Accepted risks — deliberately not fixed

**No pause, no brake.** As in `liq-locker`: an owner who can pause is an owner who can be
coerced. A locker whose operator can freeze exits is not a locker.

**A starved harvest is possible and is not an error.** If the reward balance is temporarily
below what depositors have accrued, `harvest` pays what exists and the rest stays owed.
This is preferable to reverting, which would lock the whole payout path behind the slowest
reflection.

**No recovery of LUV sent by mistake.** It becomes interest for the depositors. Stated
plainly rather than solved, because every mechanism that could return it would also be a
mechanism that could take the depositors' interest.

**Reflection dependency is unverifiable from inside.** See §4.

**Rebasing-down would break solvency.** Not applicable to LUV, which reflects upward only.
Do not reuse this contract for a token that can reduce balances.

---

## 6. Testing hazards

**T-1 — `via_ir` caches `block.timestamp`.** All tests use the absolute cursor in
`test/time_base.sol`. Never chain `vm.warp(block.timestamp + X)`.

**T-2 — `vm.expectRevert` is consumed by external calls in argument expressions.**
`test_ConstructorRejectsBadArguments` hoists `V.MAX_LOCK_DURATION()` into a local for this
reason. The same mistake produced two vacuously-passing tests in `liq-locker`.

**Block-number warping is separate from time warping.** `_mature()` advances both. A test
that only warps time will hit `block_lock_active`, which is the block lock working
correctly — not a bug in the test's subject.

---

## 7. Written since — the four gaps, closed (2026-08-13)

All four items previously listed here are done. One of them found a real bug; see D-1 in
§2b. What remains before mainnet is an **independent audit**, which is not a test and
cannot be written from inside this repository.

- [x] **Stateful invariant fuzzing** across deposit / reflect / harvest / compound /
      withdraw — `test/luv_locker_invariant.t.sol`. Seven invariants, each at 512 runs ×
      64 depth = **32,768 calls, zero reverts**: solvency, ledger-equals-people, interest
      never over-promised, index monotone, locks only lengthen, nothing exits a live lock,
      and closed-system conservation. A handler drives every mutator against four actors
      with reflections landing at random moments in between. **This is what found D-1.**
- [x] **A fork test against the real LUV token** — `test/luv_locker_fork.t.sol`, six tests,
      `make fork-test`. Forks Ethereum at HEAD, deploys against the real
      `0x2711111111683B8708cb9a48cBf36a51315F8254`, applies the real `setFeeExemption` and
      `setMaxTxExemption` as the real owner, funds depositors from the real treasury, and
      drives a real fee flush. **Reflections do land**: a measured 746,268.9 LUV arrived on
      the vault, and two depositors at a 2:1 ratio earned 1,492,537 and 746,268 — pro-rata
      on the real token, not on a mock's idea of it.
- [x] **Excluded mid-life** — `test_Fork_ExcludedMidLife_InterestFreezesPrincipalSurvives`.
      The owner excludes the vault partway through; the vault takes no share of the next
      distribution (interest freezes exactly as §4 says it silently would) and **principal
      still comes home whole at maturity**, together with the interest banked before the
      exclusion. Re-inclusion resumes accrual with no repair step.
- [x] **Precision analysis, stated numerically** — `test/luv_locker_dust.t.sol`.
      Derived: one accrual leaves `< total_principal / 1e27` wei undistributed. At LUV's
      real supply, with the **entire** supply locked, that is `1.11111e35 / 1e27` =
      **1.11111e8 wei = 0.000000000111111 LUV per accrual** — a ten-billionth of one LUV.
      Per-user settle truncates a further `< 1 wei`. Measured against the contract, and a
      thousand consecutive awkward accruals leave a residue of **4 wei** in total. The dust
      is not destroyed: it stays on the reward side as a buffer a starved harvest can draw
      on.

## 8. Pre-mainnet checklist

The first three are **operator actions on the live token**, and a fork test can only
rehearse them — `test/luv_locker_fork.t.sol` applies all three as the real owner and proves
the vault behaves correctly once they are set, but only a transaction on mainnet can tick
them. The last one is not something this repository can write for itself.

- [ ] `LUV.setFeeExemption(locker, true)` — confirmed on-chain
- [ ] `LUV.setMaxTxExemption(locker, true)` — confirmed on-chain
- [ ] Locker is **not** excluded from reflections — confirmed on-chain
- [ ] `LOCK_DURATION` decided deliberately; it is immutable
- [ ] `MIN_BLOCK_DELTA` set above the chain's realistic reorg depth
- [ ] `SURPLUS_SINK` verified by sweeping a foreign token to it on a testnet
- [ ] A reflection actually observed to accrue on a testnet before real funds
- [ ] Independent audit
