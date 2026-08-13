# luv-locker — production deployment

**Status: NOT MAINNET-CLEARED.** This is stated first because it is the only thing that
matters. Every test AUDIT §7 asked for is now written and passing, and writing them found
and fixed a real solvency bug — but the remaining item is an **independent audit**, and a
vault that holds other people's principal should not go to mainnet on its authors' word.

Verified 2026-08-13 · solc 0.8.24 · optimizer 200 · via-ir on

---

## 1. What ships

| contract | runtime | ctor |
|---|---|---|
| `luv_locker` | **5,347 B** | `(luv, lock_duration, min_block_delta, surplus_sink)` — all immutable |

The reflection vault: LUV on an extend-only timer, reflections harvestable as interest.
Principal stays locked; the growth does not. No owner, no pause, no rescue, no setter.

**It is not the live `LUVLocker 0xe07ACAde…B898`.** That one is the original and carries
audit finding **C-1 (High)** — unpatched and unpatchable, since it has no owner and no
upgrade path. Do not route the supply lock through it.

## 2. The test record

| suite | tests |
|---|---|
| default profile | **63** |
| mainnet fork (`make fork-test`) | **6** |
| **total** | **69**, 0 failing |

- **7 stateful invariants** at 512 runs × 64 calls = **32,768 calls, zero reverts**.
- **17 adversarial gate attacks**, including the C-1 attack run for real: a 1-wei deposit
  timed into a 500,000 LUV reflection is credited **1 wei**, and the reflection stays with
  the depositors who earned it.
- **Real mainnet reflections observed landing**: 746,268.9 LUV arrived on the vault, and two
  depositors at 2:1 earned 1,492,537 and 746,268 — pro-rata on the real token.
- **Excluded mid-life**: interest freezes, principal still comes home whole.
- **Dust bound as a number**: < `total_principal / 1e27` per accrual = **1.11111e8 wei** at
  LUV's full supply, a ten-billionth of one LUV.

## 3. Deploy

```bash
forge create src/luv_locker.sol:luv_locker \
  --constructor-args $LUV $LOCK_DURATION $MIN_BLOCK_DELTA $SURPLUS_SINK \
  --rpc-url mainnet --verify
```

`LOCK_DURATION` and `MIN_BLOCK_DELTA` are **immutable**. Decide them deliberately; set the
block delta above the chain's realistic reorg depth.

## 4. Before real funds

- [ ] `LUV.setFeeExemption(locker, true)` — confirmed on-chain
- [ ] `LUV.setMaxTxExemption(locker, true)` — confirmed on-chain
- [ ] Locker **not** excluded from reflections — confirmed on-chain
- [ ] Seed with a LARGE first deposit (audit L-H1: index inflation)
- [ ] A reflection observed to accrue on a testnet before real funds
- [ ] **Independent audit**

The fork rehearsal applies the first three as the real owner and proves the vault behaves
correctly once they are set — but only a mainnet transaction can tick them.

## 5. What you are trusting

**No owner.** Nothing can pause, rescue, or shorten a lock. `extend_lock` is self-only
(audit A1) — in the live vault an owner could add ten years to any depositor, repeatedly.

**A top-up re-locks the whole balance** for a fresh term. By design, not a griefing vector —
there is no `deposit_for(other)` — but say it out loud in any depositor-facing UI.

**Interest depends on a token setting this contract cannot see.** If LUV excludes the vault,
interest silently stops and nothing here can detect it. Principal remains withdrawable
throughout; both halves are proven on the fork.

**A starved harvest is not an error.** If the reward balance is briefly below what is
accrued, `harvest` pays what exists and the rest stays owed rather than reverting.

## 6. Why the audit is the gate

D-1 is the argument. A stateful fuzzer written on 2026-08-13 broke `balance >=
total_principal` by one wei through compound mode — and the consequence was not cosmetic:
the last depositor's `withdraw(principal)` reverted, leaving a wei of principal permanently
unredeemable with no owner and no rescue. Four earlier test files, 33 passing tests and two
prior audit rounds had not found it.

That is what a fresh pair of eyes does, and it is why the authors' own sign-off is not the
one that counts here.

Nothing has been deployed. No transaction has been sent.
