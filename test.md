# test.md — luv-locker

Every test, what it actually proves, and whether it passes.

```
forge test    →  33 passed · 0 failed · 0 skipped · 3 suites
solc 0.8.24 · via_ir · optimizer 200 · evm_version = paris
```

**33 / 33 ✅** — last run 2026-08-05.

A ✅ means the test was executed and passed, not that it was written. Anything unverified
is in §5 and carries no checkmark.

---

## 1. `test/luv_locker.t.sol` — principal and interest · 22 ✅

### Principal

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_DepositThenWithdrawAtMaturity` | The round trip: principal, `total_principal`, and `is_locked` all agree |
| ✅ | `test_CannotWithdrawBeforeTimeLock` | The time lock holds even once the block lock is satisfied |
| ✅ | `test_BlockLockHoldsEvenAfterTimeLockPasses` | The converse. Both locks are independent, and time alone is not enough to exit — this is what defeats enter / absorb-a-reflection / leave inside one transaction |
| ✅ | `test_DepositRelocksTheEntirePrincipal` | The stated foot-gun: a top-up pushes *all* principal to a fresh full term, not just the new amount |
| ✅ | `test_ExtendLockNeverShortens` | Maturity moves forward or reverts |
| ✅ | `test_A1_ExtendActsOnlyOnTheCallersOwnLock` | `extend_lock` takes no user argument, so there is no third-party path at all. In the live vault the owner could push any depositor's unlock out by a decade, repeatedly |
| ✅ | `test_ConstructorRejectsBadArguments` | Zero token, zero sink, zero duration, and over-horizon duration are all refused |

### Interest

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_ReflectionsBecomeClaimableInterest` | A reflection landing on the vault becomes claimable, and harvesting leaves principal locked |
| ✅ | `test_TwoDepositorsSplitReflectionsProRata` | 1,000 / 3,000 split yields 100 / 300 of a 400 reflection |
| ✅ | `test_LateDepositorEarnsNothingFromEarlierReflections` | No retroactive yield. A depositor who arrives after a reflection earns none of it |
| ✅ | `test_CompoundModeFoldsInterestIntoLockedPrincipal` | Compound mode grows principal and reports zero claimable, because pending interest there is destined to become principal rather than a claim |
| ✅ | `test_CompoundingDoesNotResetTheLockClock` | Growing the position does not extend the lock |
| ✅ | `test_HarvestNeverPaysOutOfPrincipal` | After two depositors both harvest, the balance still fully backs `total_principal` |
| ✅ | `test_HarvestWithNothingAccruedReverts` | An empty harvest is an error, not a silent no-op |

### Auto-payout

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_AutoPayoutFiresOnPoke` | A keeper pokes, the depositor is paid at their nominated address, and the keeper earns nothing. This is how a depositor gets paid without ever transacting again |
| ✅ | `test_PokeBelowThresholdPaysNothing` | The threshold is respected |

### Tokens and sweeps

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_DepositCreditsMeasuredDeltaUnderTransferFee` | Under a 5% fee, principal is 950 — **and `pending_rewards` is 0**. Nominal crediting would make the missing 5% look like reward balance, so the depositor would appear to instantly earn interest they never received |
| ✅ | `test_LuvCanNeverBeSwept` | The deployer is refused. Unclaimed LUV *is* the depositors' interest, so a sweep would be theft with a tidy name |
| ✅ | `test_ForeignTokenSweepsToTheImmutableSink` | A stranger triggers it, funds go to the immutable sink, the caller gets nothing |
| ✅ | `test_SweepWithNothingThereReverts` | Nothing to sweep is an error |

### Fuzz

| ✅ | Test | Runs | What it proves |
|:--:|---|:--:|---|
| ✅ | `testFuzz_BalanceAlwaysCoversPrincipal` | 4,096 | The solvency invariant across arbitrary deposit / reflect / poke interleavings. Nothing in this module matters more |
| ✅ | `testFuzz_PendingRewardsNeverExceedRewardBalance` | 4,096 | The vault never promises more interest than it holds |

---

## 2. `test/luv_locker_reflect_on_transfer.t.sol` — the two real defects · 2 ✅

**This suite exists because the stock mock could not express the bug.** `mock_luv` only
reflects through a separate `reflect()` call. The real ShambaLuv runs `_processFees()` at
the *top* of `_transfer`, distributing a pending reflection to every included holder —
the vault among them — **before** the transfer completes. So the vault's balance can rise
by more than the amount transferred in, inside a single `transferFrom`. A mock that cannot
do that cannot catch either finding below, and the original 22 tests all passed while both
defects were live.

| ✅ | Test | Finding | What it proves |
|:--:|---|---|---|
| ✅ | `test_ReflectionDuringDepositGoesToTheIndexNotTheDepositor` | **C-1, steal-the-yield** | An attacker front-runs with a 1-wei deposit while a 100-LUV reflection flushes during their own `transferFrom`. Before the fix, the measured delta credited the attacker with 1 wei **plus the entire reflection** as principal, and the honest depositor — who held 100% of the stake when it was earned — got nothing. Now the reflection goes to the index as the honest depositor's interest and the attacker's principal is ~1 wei |
| ✅ | `test_ReflectionDuringWithdrawIsNotOrphaned` | **M-3, orphaned reflection** | A 60-LUV reflection flushes during an outgoing withdrawal. Before the fix the trailing sync swallowed it and it was stuck in the vault balance forever, claimable by nobody. Now it becomes claimable interest for the depositors who stayed |

Both also assert `balanceOf(vault) >= total_principal` — a fix that restored the yield but
broke solvency would not pass.

---

## 3. `test/luv_locker_time.t.sol` — time · 9 ✅

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_WithdrawRevertsOneSecondBeforeMaturity` | At `unlock_at − 1` the lock holds |
| ✅ | `test_WithdrawSucceedsExactlyAtMaturity` | At exactly `unlock_at` it opens. The boundary second is inclusive, pinned rather than assumed |
| ✅ | `test_ExtendPartwayThroughPushesMaturityOut` | An extension mid-term is real: the lock is still shut at the original date |
| ✅ | `test_ExtendCannotShortenEvenAfterTimePasses` | Elapsed time creates no shortening path |
| ✅ | `test_ExtendRejectsBeyondTenYearHorizon` | The horizon is measured from *now*, so repeated extensions cannot ratchet past a decade |
| ✅ | `test_TenYearMaxHorizonLockAndWithdraw` | A position extended to the full 3,650 days: shut one second short of the decade, open one second later |
| ✅ | `test_DepositRelocksEntirePrincipalOverTime` | A 1-LUV top-up at day 360 re-locks all 1,001 LUV to a fresh full year. The old maturity passes and the position is *still* shut — the foot-gun demonstrated on a real timeline |
| ✅ | `test_CompoundingOverYearsDoesNotResetClock` | Three compounding cycles across 270 days leave `unlock_at` byte-identical, and the grown principal is withdrawable on the original schedule |
| ✅ | `test_BlockLockStillHoldsWhenTimeIsSatisfied` | Time fully satisfied but no blocks mined: still shut. Mine the blocks and it opens |

---

## 4. What changed in the contract because of these tests

C-1 and M-3 were not found by reading. They were found by building a mock that behaves the
way the real token behaves, at which point the existing suite went from 22 ✅ to 22 ✅ and
2 ❌ — and the two failures were genuine defects inherited from the live vault, not test
bugs. That is the argument for modelling the awkward part of a dependency rather than the
convenient part.

---

## 5. Not covered — no checkmark, because it has not been run

| | Gap | Why it matters |
|:--:|---|---|
| ☐ | Stateful invariant fuzzing across deposit / reflect / harvest / compound / withdraw | Current fuzz is sequential, not adversarially interleaved |
| ☐ | Fork test against the real LUV token with real exemptions applied | Every token here is a mock, including the improved one |
| ☐ | Behaviour when the vault is excluded from reflections mid-life | Interest should freeze while principal stays fully withdrawable. Believed true, untested |
| ☐ | Precision analysis of the 1e27 index at LUV's real supply scale | Index dust is described as "bounded and benign" but never computed |

---

## 6. The hazard these tests are written around

**`via_ir` caches `block.timestamp`.** Chained `vm.warp(block.timestamp + X)` reuses the
first value. All time moves through the absolute cursor in `test/time_base.sol`.

**Two clocks, not one.** `_mature()` advances *both* time and block number. A test that
only warps time hits `block_lock_active` — that is the block lock working, not a bug in
the test's subject.

---

## 7. Reproducing

```sh
make test                 # all 33
make audit                # the regression subset
forge test --match-path 'test/luv_locker_reflect_on_transfer.t.sol' -vvv
python3 ../scripts/check_test_md.py     # verifies this file against a live run
```
