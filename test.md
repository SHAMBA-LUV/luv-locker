# test.md — luv-locker

Every test, what it actually proves, and whether it passes.

```
forge test                 →  75 passed · 0 failed · 1 skipped · 9 suites
FORK_TEST=1 (make fork-test) →  7 passed on real LUV, 2026-10-13
make test-200y             →  the 70 again against luv_locker_200y: 70 passed · 1 skipped; fork 7/7
solc 0.8.24 · via_ir · optimizer 200 · evm_version = paris
```

**75 / 75 ✅** — last run 2026-10-13. The 7 mainnet-fork tests are skipped offline, so they carry ☐ here (§3e) and were run separately.

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
| ✅ | `test_DepositRefusedUnderTransferFee` | Under a 5% fee the deposit reverts `not_fee_exempt` and nothing moves. Replaced the old "credit the 950 that arrived" test on 2026-10-12 (H-2): a fee and a mid-deposit reflection in one delta cannot be told apart, so crediting either way can hand one depositor another's interest |
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

## 3a. `test/gate_attack.t.sol` — adversarial gate attacks · 17 ✅

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_attack_WithdrawOneSecondEarlyFails` | One second before maturity, with every block mined, the time lock still holds |
| ✅ | `test_attack_WithdrawExactlyAtMaturitySucceeds` | At maturity exactly, principal comes home whole |
| ✅ | `test_attack_ProposerDriftCannotOpenTheLock` | A proposer's few seconds of timestamp drift do not buy an early exit |
| ✅ | `test_attack_SecondDepositCannotShortenTheLock` | A second deposit only ever pushes maturity out |
| ✅ | `test_attack_TopUpRelocksTheWholeBalance` | The documented foot-gun, pinned: a top-up re-locks the whole balance, and only the depositor can do it to themselves |
| ✅ | `test_attack_CannotRelockAnotherUser` | There is no deposit-for-someone-else, so nobody can re-lock another balance |
| ✅ | `test_attack_BlockLockHoldsWhenTimeHasPassed` | Time satisfied, blocks not: still shut |
| ✅ | `test_attack_NoAmountOfTimeSkipsABlock` | No warp, however large, substitutes for mined blocks |
| ✅ | `test_attack_C1_DustDepositCannotAbsorbAReflection` | C-1 run for real: a 1-wei deposit timed into a 500,000 LUV flush is credited 1 wei; the reflection stays with the depositors who earned it |
| ✅ | `test_attack_LateDepositorCannotRetroEarn` | A late depositor earns nothing distributed before they arrived |
| ✅ | `test_attack_NobodyCanExtendAnotherUsersLock` | `extend_lock` acts only on the caller |
| ✅ | `test_attack_ExtendLockCannotShorten` | An extension earlier than the current maturity reverts |
| ✅ | `test_attack_ExtendLockCannotExceedTheHorizon` | An extension past `MAX_LOCK_DURATION` reverts |
| ✅ | `test_attack_CannotWithdrawMoreThanPrincipal` | Over-withdrawal reverts |
| ✅ | `test_attack_CannotWithdrawSomeoneElsesPrincipal` | Principal is per-address; a stranger cannot take it |
| ✅ | `test_attack_LuvCanNeverBeSweptOut` | `sweep_foreign(LUV)` reverts for every caller, and principal survives the attempt |
| ✅ | `test_attack_HarvestDoesNotUnlockPrincipal` | Interest is claimable while principal stays locked, and only by its depositor |

## 3b. `test/luv_locker_dust.t.sol` — index dust and D-1 · 6 ✅

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_DustPerAccrualIsBelowTheDerivedBound` | The whole supply locked, then a reflection: the undistributed remainder is below `total_principal / 1e27` = 1.11111e8 wei |
| ✅ | `test_DustStaysInTheVaultAsRewardBalance` | The dust is not destroyed; it stays on the reward side for a later harvest |
| ✅ | `test_DustDoesNotAccumulateAcrossManyAccruals` | A thousand accruals do not compound the loss into anything meaningful |
| ✅ | `test_D1_CompoundCanOvercreditPrincipalByDust` | Pins the D-1 behaviour the fuzzer found: compounding could over-credit principal by dust before the cap |
| ✅ | `test_D1_ShortfallCannotStrandAWithdrawal` | The consequence that decides severity: every depositor exits, in the worst order, and each is paid |
| ✅ | `test_D1_RealisticScaleExitsCleanly` | The same at realistic scale |

## 3c. `test/luv_locker_invariant.t.sol` — stateful invariants · 7 ✅

512 runs × 64 calls across deposit / reflect / harvest / compound / withdraw / poke.

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `invariant_BalanceCoversAllPrincipal` | I1 solvency: principal is always fully backed |
| ✅ | `invariant_TotalPrincipalIsTheSumOfPrincipals` | I2: the ledger equals the people |
| ✅ | `invariant_InterestOwedFitsInTheRewardBalance` | I3: interest owed never exceeds the non-principal balance |
| ✅ | `invariant_IndexIsMonotone` | I4: the index only rises |
| ✅ | `invariant_LocksOnlyLengthen` | I5: locks only lengthen |
| ✅ | `invariant_NoPrincipalEscapesALiveLock` | I6: a live lock's principal cannot fall |
| ✅ | `invariant_NothingIsCreatedOrDestroyed` | I7: every wei is in the vault or in someone's hand; reflections are the only source |

## 3d. `test/luv_locker_review_2026_10.t.sol` — the 2026-10-12 review findings · 7 ✅

Each finding's attack, as the reviewer wrote it, passed against the old source and fails against the fixed one (AUDIT.md §2c).

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_H1_index_inflation_no_longer_bricks_deposits` | H-1: 1 wei + a 1e30 donation + harvest inflates the index to 1e57; a billion-LUV deposit still succeeds, owes nothing, earns correctly and withdraws whole |
| ✅ | `testFuzz_H1_mul_acc_matches_naive_where_naive_fits` | `_mul_acc` equals `a*b/1e27` on every input where that does not overflow |
| ✅ | `test_H1_mul_acc_exact_beyond_naive` | `_mul_acc` is exact past the overflow point, checked against Python big-int values |
| ✅ | `test_H2_fee_paying_deposit_is_refused` | H-2: with the fee on, the 1000 + 40-reflection attack reverts `not_fee_exempt` |
| ✅ | `test_H2_exempt_flush_goes_to_incumbent` | With the exemption, a reflection flushing during the attacker's deposit goes wholly to the incumbent; the attacker is credited exactly 1000 |
| ✅ | `test_M4_deposit_time_reflection_is_not_orphaned` | M-4: Alice gets all 100 of a reflection flushing during Bob's 9000 deposit, Bob 0, and the vault ends empty |
| ✅ | `test_M4_top_up_keeps_own_share_of_flush` | A top-up keeps its own share of a reflection flushing during it (1000 of 4000 earns a quarter) |

## 3f. `test/luv_locker_200y.t.sol` — the 200-year horizon · 5 ✅

`src/luv_locker_200y.sol` is `luv_locker` with `MAX_LOCK_DURATION` = 73,050 days (200 years) in place of 3,650. The original is kept unchanged. These tests cover only the horizon, mostly side by side with the original. Everything else is shown by `make test-200y`, which checks that the two sources differ only in that constant and then runs the whole suite above against `luv_locker_200y`: 70 passed, 1 skipped offline, and the 7 fork tests passed on real LUV on 2026-10-13.

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_200y_HorizonIsTwoCenturies` | The horizon is 73,050 days (200 × 365.25), and the original still reads 3,650 |
| ✅ | `test_200y_ConstructorAcceptsTwoCenturiesRejectsOneSecondMore` | A 200-year `LOCK_DURATION` deploys; one second more is refused; the original refuses the same 200-year argument |
| ✅ | `test_200y_ExtendPastADecadeOnlyOnTheTwoCenturyLock` | An eleven-year `extend_lock` reverts on the original and lands on the 200-year lock |
| ✅ | `test_200y_ExtendRejectsBeyondTwoCenturies` | `extend_lock` past now + 200 years reverts `duration_too_long` |
| ✅ | `test_200y_FullHorizonLockHarvestAndWithdraw` | A full two-century lock: eight reflections over the term are all harvested as interest, the principal is locked one second before the horizon, and it withdraws whole at it |

## 3e. `test/luv_locker_fork.t.sol` — the real LUV token · 7, fork only

Skipped by `forge test`; run with `make fork-test` (FOUNDRY_PROFILE=fork, FORK_TEST=1). All 7 passed on 2026-10-12 against mainnet state.

| | Test | What it proves |
|:--:|---|---|
| ☐ | `test_Fork_TheRealTokenAndTheRealExemptions` | The token and owner are what we think, and the exemptions took |
| ☐ | `test_Fork_NonExemptLockerRefusesDeposits` | H-2 on the real token: a locker LUV does not list as fee-exempt refuses deposits, read from `isExcludedFromFee`; once exempted, it accepts |
| ☐ | `test_Fork_FeeExemptDepositCreditsTheFullAmount` | A fee-exempt deposit of real LUV credits the full amount and comes back whole |
| ☐ | `test_Fork_RealReflectionsLandOnTheVault` | A genuine reflection, produced through `processFees()`, lands and is claimable as interest |
| ☐ | `test_Fork_ExcludedMidLife_InterestFreezesPrincipalSurvives` | Excluded mid-life: interest freezes, principal still comes home |
| ☐ | `test_Fork_ReIncludedAfterExclusionResumesInterest` | Re-included: interest resumes with no repair step |
| ☐ | `test_Fork_TwoDepositorsSplitARealReflection` | Two depositors at 2:1 split a real reflection pro-rata |

---

## 4. What changed in the contract because of these tests

C-1 and M-3 were not found by reading. They were found by building a mock that behaves the
way the real token behaves, at which point the existing suite went from 22 ✅ to 22 ✅ and
2 ❌ — and the two failures were genuine defects inherited from the live vault, not test
bugs. That is the argument for modelling the awkward part of a dependency rather than the
convenient part.

---

## 5. Not covered — no checkmark, because it has not been run

The four gaps listed here on 2026-08-05 are closed: stateful invariants (§3c), the real-token
fork (§3e), exclusion mid-life (§3e), and the dust bound at real supply (§3b).

| | Gap | Why it matters |
|:--:|---|---|
| ☐ | Independent audit | Every test here was written by the authors of the contract |

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
make test                 # all 75 (+1 fork suite skipped)
make test-200y            # the whole suite again against luv_locker_200y
make fork-test            # the 7 against real LUV
make audit                # the regression subset
forge test --match-path 'test/luv_locker_reflect_on_transfer.t.sol' -vvv
python3 ../scripts/check_test_md.py     # verifies this file against a live run
```
