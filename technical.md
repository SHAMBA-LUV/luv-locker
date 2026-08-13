# technical.md — luv-locker

---

## 1. System shape

```
   ┌──────────────────────────┐
   │       LUV token          │  reflects to holders
   └────────────┬─────────────┘
                │ reflections land on the balance
   ┌────────────▼─────────────┐
   │       luv_locker         │  principal timelock + staking index
   └──────────────────────────┘
```

One contract, one token, no external calls except to LUV itself. Nothing points back up:
the locker cannot configure the token, and the token does not know the locker exists
beyond the exemption flags an operator sets on it.

---

## 2. Why this is a separate module

The live vault runs the reflection pool **and** holds generic ERC-20 timelocks including
the LP token. Three consequences, all visible in the original source:

- The reward balance had to be `balance − principal − totalAssetLocked[LUV]`. A
  three-term subtraction is wrong if any term is missed.
- `if (token == LUV)` appeared in `lockAsset`, `withdrawAsset`, `rescue`, `_surplus`, and
  the accrue/sync calls around each. Every branch had to remember to call `_accrue` first
  and `_syncRewardBalance` afterwards. Each case reads correctly in isolation — which is
  exactly why this class of bug survives review.
- `rescue` needed a different surplus computation for LUV than for every other token.

Splitting the module deletes all of it. Here the reward balance is
`balance − total_principal`, and there is no token identity check anywhere in the file,
because the contract holds exactly one token.

This is BANKON's standing rule — folder boundaries are load-bearing and must never be
collapsed for convenience — applied to a case where collapsing them was actively
generating bug surface rather than merely being untidy.

If you want to lock LP tokens, that is `../liq-locker`.

---

## 3. Threat model

### In scope, mitigated

| Threat | Mitigation |
|---|---|
| Owner extends a depositor's lock | no owner; `extend_lock` takes no user argument |
| Owner drains principal or interest | no owner; LUV can never be swept by anyone |
| Griefer sweeps interest as "surplus" | `sweep_foreign` reverts on LUV unconditionally |
| Sweep destination redirected | `SURPLUS_SINK` immutable; caller chooses nothing |
| Flash enter / absorb reflection / exit | block lock, `MIN_BLOCK_DELTA` |
| Late depositor claiming earlier yield | staking index with `reward_debt` at deposit |
| Fee-on-transfer breaking accounting | deposits credit the measured balance delta |
| Fee miscounted as interest | index accrues from balance, principal from the delta |
| Over-payment draining principal | `_pay_accrued` caps at the real reward balance |
| Reentrancy | mutex on every mutator |
| Read-only reentrancy | `when_not_entered` on every view |
| Compounding silently extending the lock | `_settle` never touches `unlock_at` |

### In scope, NOT mitigated

**Reflection inclusion is unverifiable from inside.** If the token excludes this contract,
interest stops accruing silently. No revert, no event, nothing detectable here. It is an
operational invariant, checked on-chain, not a code property. Principal remains fully
withdrawable — the lock still works, it just stops earning.

**A bug here is permanent.** No pause, no owner, no upgrade.

**Rebasing-down would break solvency.** Not applicable to LUV, which reflects upward only.
Do not reuse this contract for a token that can reduce balances.

**Depositor key loss is unrecoverable.** There is no `assign` here — a reflection position
is inherently per-depositor. `set_auto_payout` plus `poke` lets someone else's transaction
pay a depositor who cannot transact, which covers the "no gas" case but not the "no key"
case.

**Index dust.** Floor division leaves dust that re-enters the reward balance on the next
accrual. Bounded and benign, but see `AUDIT.md` §7 — the worst-case bound is described
rather than computed, and should be computed before mainnet.

---

## 4. Long-horizon design notes

### Storage layout

`user_info` is five slots. Four full words (`principal`, `reward_debt`, `accrued`,
`auto_threshold`) and one packed:

```
payout (160) + unlock_at (48) + deposit_block (40) + lock_interest (8) = 256 bits exactly
```

`deposit_block` as `uint40` holds ~1.1×10¹² blocks — 418,000 years at 12s. `unlock_at` as
`uint48` overflows in the year 8,921,556. `uint32` would overflow in 2106, inside the
design horizon.

### Block numbers for the short lock, timestamps for the long one

`MIN_BLOCK_DELTA` is deliberately measured in blocks and `LOCK_DURATION` deliberately in
seconds. Block counts are the right unit for "same transaction / adjacent blocks", where
the adversary is an atomic sandwich. They are the wrong unit for a year, because block
time is not a constant and never has been.

### Classic mutex, not transient storage

`evm_version = "paris"`. Same reasoning as the rest of the house: take the gas, keep the
certainty across EVM upgrades.

### No dependencies

`src/in_house.sol` and nothing else. `forge-std` appears only under `test/`.

---

## 5. cypherpunk2048 compliance

| Rule | Status |
|---|---|
| Apache-2.0 | yes |
| No admin keys post-deploy | yes — no owner, no roles, no pause, no setters |
| No upgradeable proxies | yes |
| Flat snake_case layout | yes — files, contracts, functions, errors |
| Custom errors, no revert strings | yes |
| Comment block before `pragma` | yes |
| One `docs/<name>.md` per `.sol` | yes |

No exception is claimed.

---

## 6. Gas

- `deposit`: two `balanceOf` calls (the measured delta, not optional) plus `_accrue`,
  `_settle`, four SSTOREs and `_sync`.
- `withdraw`: `_accrue` + `_settle` + three SSTOREs + transfer.
- `harvest`: `_accrue` + `_settle` + one transfer.
- `poke`: same as harvest, callable by anyone — the gas is paid by the poker, which is
  the point.
- `pending_rewards`: one `balanceOf`, pure arithmetic otherwise.

Run `make gas` and `make sizes` before deploying.

---

## 7. Test coverage map

| Area | Test |
|---|---|
| A1 — extension is self-only | `test_A1_ExtendActsOnlyOnTheCallersOwnLock` |
| Deposit / withdraw round trip | `test_DepositThenWithdrawAtMaturity` |
| Time lock | `test_CannotWithdrawBeforeTimeLock` |
| Block lock independent of time | `test_BlockLockHoldsEvenAfterTimeLockPasses` |
| Reflections become interest | `test_ReflectionsBecomeClaimableInterest` |
| Pro-rata split | `test_TwoDepositorsSplitReflectionsProRata` |
| No retroactive yield | `test_LateDepositorEarnsNothingFromEarlierReflections` |
| Compound folds into principal | `test_CompoundModeFoldsInterestIntoLockedPrincipal` |
| Compounding does not reset the lock | `test_CompoundingDoesNotResetTheLockClock` |
| Harvest never touches principal | `test_HarvestNeverPaysOutOfPrincipal` |
| Auto-payout via keeper | `test_AutoPayoutFiresOnPoke` |
| Below-threshold poke is a no-op | `test_PokeBelowThresholdPaysNothing` |
| Deposit re-locks everything | `test_DepositRelocksTheEntirePrincipal` |
| Measured delta under fee | `test_DepositCreditsMeasuredDeltaUnderTransferFee` |
| LUV can never be swept | `test_LuvCanNeverBeSwept` |
| Foreign sweep to immutable sink | `test_ForeignTokenSweepsToTheImmutableSink` |
| Extend-only | `test_ExtendLockNeverShortens` |
| Constructor bounds | `test_ConstructorRejectsBadArguments` |
| Solvency under fuzz | `testFuzz_BalanceAlwaysCoversPrincipal` |
| Promises are backed under fuzz | `testFuzz_PendingRewardsNeverExceedRewardBalance` |

**22 tests, all passing** under solc 0.8.24 with `via_ir`. Gaps are in `AUDIT.md` §7.
