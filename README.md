# luv-locker

Timelocked SHAMBA LUV principal earning reflection interest. No owner.

Principal is locked. Interest never is.

## Contracts

| File | License | Purpose |
|---|---|---|
| `src/luv_locker.sol` | `Apache-2.0` | reflection pool + principal timelock, ownerless |
| `src/in_house.sol` | `Apache-2.0` | zero-dependency ERC-20 helpers and reentrancy guards |

## Status

Compiles under solc 0.8.24 with `via_ir`. **33 tests, 3 suites, all passing.**
Every test is listed with a description and its pass status in [`test.md`](test.md);
`make testmd` re-runs the suite and fails if that file has drifted from reality.
`luv_locker` is 5,331 bytes runtime, against the 24,576-byte EIP-170 limit.

## Quick start

```sh
make test
make audit     # the regression suite for the inherited findings
```

## What this derives from

SHAMBA LUV's `LUVLocker` and its 2026-08-03 audit. The reward accounting is the part
that audit verified, and it is carried across substantially intact: a staking-pool index
at 1e27, reward defined as the balance nobody has claimed, accrue-then-settle ordering at
every mutator, payouts capped at the real reward balance so a harvest can starve but never
revert-lock and never over-pay.

## The change that matters most

The live vault does two jobs in one contract: it runs this reflection pool **and** it holds
generic ERC-20 timelocks including the LP token. That forced every reward computation to
subtract `totalAssetLocked[LUV]`, and forced `if (token == LUV)` special cases through eight
different functions — the exact shape of bug that survives review because each individual
case looks right.

The generic timelock now lives in its own module (`../liq-locker`). Here the reward balance
is simply `balanceOf(this) - total_principal`. There is nothing to special-case because
there is nothing else in the contract.

If you want to lock LP tokens, that is `liq-locker`. This module holds LUV and only LUV.

## Why LUV can never be swept

In `liq-locker`, surplus is any balance no lock claims, and sweeping it to a fixed sink is
safe housekeeping. Here the balance no depositor claims **is the interest** — it is the
reflections in transit. A surplus sweep would be a theft of yield with a tidy name.

So `sweep_foreign` refuses LUV unconditionally. LUV sent here by mistake becomes interest
for the depositors. There is no path, privileged or otherwise, that moves LUV out of this
contract except a depositor's own `withdraw` or `harvest`.

## The invariant that is not in the code

Interest accrues only while this contract stays **reflection-included** on the LUV token,
and deposits require fee and max-tx exemption. Those are settings on the token, not here.

If the token excludes this contract, interest silently stops accruing and **nothing in
this repository can detect it**. Check it on-chain after deployment and after any change
to the token. `usage.md` §2 has the calls.

## Two documented foot-guns

- **A deposit re-locks everything.** Topping up a position that matures next week pushes
  *all* of it out to a fresh full term. Extend-only culture applied consistently. Use a
  second address if you want the old position to mature on schedule.
- **`LOCK_DURATION` is immutable.** The live vault let an owner change it for future
  deposits. A different horizon now means a different deployment.
