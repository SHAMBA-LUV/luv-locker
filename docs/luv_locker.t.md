# luv_locker.t.sol

22 tests over the reflection lock.

## The mock that carries the whole suite

`mock_luv.reflect(to, amount)` raises a holder's balance with **no transfer and no
sender** — which is exactly what an RFI-style token does to a reflection-included address.
Everything the locker calls interest is produced this way. `set_fee_bps` turns on a
transfer fee so the not-fee-exempt case can be tested too.

## Two clocks

`_mature()` advances **both** time and block number, because the locker has two locks.
A test that only warps time hits `block_lock_active` — that is the block lock working, not
a bug in the test's subject.

Time uses the absolute cursor in `time_base.sol`. Never chain
`vm.warp(block.timestamp + X)`; `via_ir` caches the timestamp and the second warp is a
no-op.

## Groups

| Group | Covers |
|---|---|
| principal | round trip, time lock, block lock independence |
| interest | reflections become claimable, pro-rata split, no retroactive yield |
| compounding | folds into principal, does not reset the lock clock |
| starvation | harvest never pays out of principal; empty harvest reverts |
| auto-payout | keeper `poke` pays to the nominated address, earns nothing itself |
| A1 | extension acts only on the caller's own position |
| fee tokens | measured delta; the fee is not miscounted as interest |
| sweeps | LUV can never be swept; foreign tokens go to the immutable sink |
| fuzz | solvency; pending never exceeds the reward balance |

## The two tests worth reading first

**`test_LuvCanNeverBeSwept`** — the asymmetry with `liq-locker` and the reason the two
modules cannot share a sweep implementation. There, unclaimed balance is stray tokens and
sweeping is housekeeping. Here, unclaimed balance *is* the depositors' interest, and
sweeping would be theft with a tidy name. The test pranks as the deployer to make the
point that there is no privileged exception.

**`testFuzz_BalanceAlwaysCoversPrincipal`** — the solvency invariant, over arbitrary
interleavings of deposit, reflect, and poke. If the vault's balance ever falls below the
principal it claims to hold, somebody cannot withdraw. Nothing else in the file matters
more.

## A note on `test_DepositCreditsMeasuredDeltaUnderTransferFee`

It asserts two things, and the second is the subtle one:
`pending_rewards(alice) == 0`. Crediting the requested amount rather than the delta would
not only inflate principal — it would make the *missing* 5% look like reward balance, so
the depositor would appear to have instantly earned interest they never received.
