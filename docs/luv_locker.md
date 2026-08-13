# luv_locker.sol

Timelocked SHAMBA LUV principal earning reflection interest. Ownerless.

`Apache-2.0` · 5,331 bytes runtime · no dependencies

---

## What it is

A staking pool where the reward is not minted or funded — it simply *arrives*, because
the LUV token reflects to holders and this contract is a holder. Everything above
`total_principal` is interest, and it is distributed pro rata by a standard index.

Principal is locked by both a timestamp and a block count. Interest never is.

## Interface

| Function | Who | Notes |
|---|---|---|
| `deposit(amount)` | anyone | **re-locks the entire principal** |
| `withdraw(amount)` | self | after both time and block locks pass; partial allowed |
| `harvest()` | self | claim accrued interest; reverts if nothing accrued |
| `extend_lock(new_unlock_at)` | self | forward only. Takes no user argument |
| `set_interest_mode(bool)` | self | false = claimable, true = compound into principal |
| `set_auto_payout(threshold, payout)` | self | zero threshold disables |
| `poke(user)` | **anyone** | settles a user and pays them if over threshold |
| `sweep_foreign(token)` | **anyone** | to `SURPLUS_SINK`. **Reverts on LUV** |
| `pending_rewards(user)` | view | includes not-yet-accrued reflections |
| `is_locked(user)` | view | true while either lock holds |
| `reward_balance()` | view | the undistributed pool |

## Constructor

```solidity
constructor(address luv_, uint48 lock_duration_, uint256 min_block_delta_, address surplus_sink_)
```

All immutable. `LOCK_DURATION` in particular: the live vault had `setLockDuration`, and
this does not. A different horizon means a different deployment.

## The accounting

A staking-pool index at 1e27 (`ACC_SCALE`), which is nine decimals more than the usual
1e18. The index divides by `total_principal`, and LUV's supply is large enough that an
18-decimal index loses meaningful precision on small reflection deltas.

```
reward_balance      = balanceOf(this) − total_principal
acc_reward          += (reward_balance − last_reward_balance) × 1e27 / total_principal
user pending        = principal × acc / 1e27 − reward_debt
```

Every mutator follows the same order: `_accrue()` → `_settle(user)` → mutate → `_sync()`.

**The single-token simplification.** In the live vault this had to be
`balance − principal − totalAssetLocked[LUV]`, with `if (token == LUV)` special cases in
eight functions. Generic asset locks now live in `../liq-locker`, so the reward balance
here is a one-term subtraction and there is no token identity check anywhere in the file.
That is the most valuable thing about splitting the modules.

## Two locks, not one

`unlock_at` (timestamp) **and** `deposit_block + MIN_BLOCK_DELTA` (block count). Both must
pass. Time alone would allow enter / absorb-a-reflection / leave inside one transaction.
`test_BlockLockHoldsEvenAfterTimeLockPasses` covers it.

## Interest modes

**Claimable** (default) — interest accrues to `accrued` and can be harvested at any time
while principal stays locked.

**Compound** — settled interest is folded into locked principal instead, growing the
position and maturing with it. Switching settles under the *old* mode first, so a switch
never reclassifies interest already earned. **Compounding does not reset the lock clock**
(`test_CompoundingDoesNotResetTheLockClock`).

In compound mode `pending_rewards` reports only the already-accrued claimable balance,
because pending interest there is destined to become principal rather than a claim.

## Payouts can starve, and that is correct

`_pay_accrued` caps at the real reward balance. If less is available than a user has
accrued, they are paid what exists and the rest stays owed. The alternative — reverting —
would put the entire payout path behind the slowest reflection.

## Why LUV can never be swept

In `liq-locker`, surplus is any balance no lock claims, and sweeping it is safe. Here the
balance no depositor claims **is the interest**. A surplus sweep would be a theft of yield
with a tidy name, so `sweep_foreign` refuses LUV unconditionally.

There is no path, privileged or otherwise, that moves LUV out of this contract except a
depositor's own `withdraw` or `harvest`. LUV sent here by mistake becomes interest for the
depositors. `test_LuvCanNeverBeSwept`.

## Stated foot-gun

**A deposit re-locks the entire principal**, not just the new amount. Topping up a
position maturing next week pushes all of it to a fresh full term. The original audit
flagged this as intentional-but-unstated; it is now stated in three places and tested.

## The invariant that is not a code property

Interest accrues only while this contract stays **reflection-included** on the LUV token,
and deposits need fee and max-tx exemption. Those are settings on the token. If the token
excludes this contract, interest silently stops, nothing reverts, no event fires, and
nothing here can detect it. Check it on-chain. `usage.md` §2 has the calls.

## Tests

`test/luv_locker.t.sol` — 22 tests.
