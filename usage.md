# usage.md — luv-locker

---

## 1. Build and test

```sh
make test      # 22 tests
make audit     # the regression suite — never skip before a deployment
make sizes
```

`lib/forge-std` is a symlink; repoint it if dangling. `src/` imports nothing else.

---

## 2. The token settings that decide whether this works at all

**None of these are in this repository.** They are calls on the LUV token, and if they are
wrong the locker compiles, deploys, accepts deposits, and quietly earns nothing.

```sh
# deposits and withdrawals are contract transfers — they must not pay the
# buy/sell fee or hit the max-tx cap
cast send $LUV "setFeeExemption(address,bool)"   $LOCKER true
cast send $LUV "setMaxTxExemption(address,bool)" $LOCKER true
```

**And the one that is a prohibition rather than a call: never exclude the locker from
reflections.** The reflections landing on this contract's balance *are* the interest. If
the token stops sending them, `pending_rewards` simply stops growing, no event is emitted,
nothing reverts, and nothing in this repository can detect it.

Verify after deployment, and again after any change to the token:

```sh
cast call $LUV "isExcludedFromReflection(address)(bool)" $LOCKER   # must be false
cast call $LOCKER "reward_balance()(uint256)"                      # must grow over time
```

---

## 3. Pre-deploy decisions that cannot be changed afterward

**`LOCK_DURATION`** — immutable. The live vault let an owner change it for future
deposits; this does not. A different horizon means a different deployment.

**`MIN_BLOCK_DELTA`** — blocks that must pass after a deposit before withdrawal. Defeats
enter / absorb-a-reflection / leave inside one transaction. Set it above the chain's
realistic reorg depth.

**`SURPLUS_SINK`** — where *foreign* tokens go when swept. Never receives LUV, ever.

**`LUV_TOKEN`** — the token address. Wrong value means a locker for the wrong asset.

```sh
export LUV_TOKEN=0x...
export LOCK_DURATION=31536000     # 365 days, in seconds
export MIN_BLOCK_DELTA=10
export SURPLUS_SINK=0x...

make fork
make deploy
```

---

## 4. Operating

**Deposit** (`deposit(amount)`) — approve first. Locks for `LOCK_DURATION` from now.

> **A deposit re-locks your entire principal**, not just the new amount. Topping up a
> position that matures next week pushes all of it out to a fresh full term. If you want
> the old position to mature on schedule, use a second address.

**Withdraw** (`withdraw(amount)`) — after both the time lock and the block lock pass.
Partial withdrawals are allowed.

**Harvest** (`harvest()`) — claim accrued interest. Principal stays locked. Reverts if
nothing has accrued.

**Interest mode** (`set_interest_mode(bool)`) — `false` (default) accrues claimable
interest; `true` folds it into locked principal instead. Settles under the old mode first,
so switching never reclassifies interest already earned. Compounding does **not** reset
the lock clock.

**Auto-payout** (`set_auto_payout(threshold, payout)`) — pays out automatically once
accrued interest reaches `threshold`. Zero disables. `payout` of `address(0)` means self.

**Poke** (`poke(user)`) — anyone may call it on anyone. Settles the user and pays them if
they are over their threshold. This is how a depositor gets paid without ever transacting
again, which matters for a lock measured in years.

**Sweep** (`sweep_foreign(token)`) — permissionless, to `SURPLUS_SINK`. **Reverts on LUV.**

---

## 5. Reading the state

```sh
cast call $LOCKER "pending_rewards(address)(uint256)" $USER   # claimable now
cast call $LOCKER "is_locked(address)(bool)"          $USER   # time OR block lock holds
cast call $LOCKER "reward_balance()(uint256)"                 # the undistributed pool
cast call $LOCKER "total_principal()(uint256)"
cast call $LOCKER "users(address)" $USER
```

Solvency check anyone can run: `LUV.balanceOf(locker) >= locker.total_principal()`.
If that is ever false, something is badly wrong — it is fuzz-tested to hold.

Note that `pending_rewards` returns only already-accrued interest when the user is in
compound mode, because pending interest there is destined to become principal rather than
a claim.

---

## 6. Emergency procedures

There are none. No pause, no owner, no upgrade. What is actually available:

- **The token excludes the locker from reflections.** Interest freezes. Principal remains
  fully withdrawable at maturity — the lock still works, it just stops earning. Fix it on
  the token; nothing here needs changing.
- **A harvest pays less than expected.** The reward balance was below what was accrued.
  This is a starved harvest, not a failure: the remainder stays owed and is payable later.
- **LUV sent here by mistake.** It becomes interest for the depositors. There is no
  recovery path, deliberately — any mechanism that could return it could also take the
  depositors' interest.
- **A compromised depositor key.** There is no `assign` here; a reflection position is
  inherently per-depositor. Withdraw at maturity to a safe address and re-deposit from it.

---

## 7. Annual review

- [ ] Locker still reflection-included on the token — checked, not assumed
- [ ] Fee and max-tx exemptions still in place
- [ ] `LUV.balanceOf(locker) >= total_principal()` holds
- [ ] `reward_balance()` has grown since the last review
- [ ] Depositor keys still signable
- [ ] Maturity dates diarized
