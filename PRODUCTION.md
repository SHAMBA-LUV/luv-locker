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

2026-10-12: three more findings (H-1 index-inflation DoS, H-2 C-1 residual without fee
exemption, M-4 stranded deposit-time reflection) found by review and fixed — `AUDIT.md` §2c.

| suite | tests |
|---|---|
| default profile | **75** (70 + 5 for the 200-year horizon) |
| mainnet fork (`make fork-test`) | **7** |
| **total** | **82**, 0 failing |
| `make test-200y`: the whole suite against `luv_locker_200y` | **70** + **7** fork, 0 failing |

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

For the 200-year horizon, deploy `src/luv_locker_200y.sol:luv_locker_200y` with the same
arguments. Choose before deploying: the horizon is a constant and cannot be changed later.

`LOCK_DURATION` and `MIN_BLOCK_DELTA` are **immutable**. Decide them deliberately; set the
block delta above the chain's realistic reorg depth.

## 4. Before real funds

- [ ] `LUV.setFeeExemption(locker, true)` — confirmed on-chain (since H-2 the vault refuses every deposit until this is set)
- [ ] `LUV.setMaxTxExemption(locker, true)` — confirmed on-chain
- [ ] Locker **not** excluded from reflections — confirmed on-chain
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

## 6. Why not OpenZeppelin

An auditor's first question about a custody contract is why it is not the audited library
version. Here the answer is unusually clean: **OpenZeppelin tells you to build this
yourself.**

Checked against **OpenZeppelin Contracts v5.7.0**, commit `0742777`, read from source.

`TokenTimelock` was **removed in v5.0** — changelog: *"`TokenTimelock` (in favor of
`VestingWallet`)"* — along with every escrow contract. What remains is
`finance/VestingWallet.sol`, and on the exact problem this vault exists to solve it says:

> *"When using this contract with any token whose balance is adjusted automatically (i.e. a
> rebase token), make sure to account the supply/balance adjustment in the vesting schedule
> to ensure the vested amount is as intended."*

That is a warning, not a mechanism. LUV is precisely such a token — it reflects upward
during a transfer — and a `VestingWallet` holding it would be actively wrong, not merely
unsuitable: its `vestedAmount` is computed against `balanceOf(this) + released()`, so every
reflection would be treated as *"locked from the beginning"* and **vested away on the
schedule** instead of paid out as harvestable interest. The reward-index machinery in this
file is the thing that warning tells you to go and write.

| | OZ `VestingWallet` | `luv_locker` |
|---|---|---|
| owner | `Ownable`, transferable | **none** |
| reflections | vested away on the schedule | **harvestable interest**, principal untouched |
| tokens sent later | *"partly immediately releasable"* | credited to the index, pro-rata to existing principal |
| block gate | none (`block.number` appears **zero times**) | **yes**, alongside the time lock |
| lock shape | linear vesting; `duration = 0` degenerates to a timelock | all-or-nothing at maturity, extend-only |
| many depositors | one deployment each | one contract, per-account accounting |

Two more of OpenZeppelin's own caveats are worth reading next to this vault:

- *"Since the wallet is {Ownable}, and ownership can be transferred, it is possible to sell
  unvested tokens."* There is no owner here at all, and `extend_lock` is self-only (audit
  A1) — in the **live** `LUVLocker` an owner could add ten years to any depositor's lock,
  repeatedly, which is the hostage mechanism this rewrite removes.
- *"Any assets transferred to this contract will follow the vesting schedule as if they were
  locked from the beginning."* Here a stray transfer becomes interest for the existing
  depositors, and `sweep_foreign` **cannot take LUV at all**.

**The honest summary:** no OpenZeppelin contract could have been used instead. That is not a
claim this one is better — OpenZeppelin's are audited and this is not, which is the whole of
§4's last box and of §7 below.

## 7. Why the audit is the gate

D-1 is the argument. A stateful fuzzer written on 2026-08-13 broke `balance >=
total_principal` by one wei through compound mode — and the consequence was not cosmetic:
the last depositor's `withdraw(principal)` reverted, leaving a wei of principal permanently
unredeemable with no owner and no rescue. Four earlier test files, 33 passing tests and two
prior audit rounds had not found it.

That is what a fresh pair of eyes does, and it is why the authors' own sign-off is not the
one that counts here.

Nothing has been deployed. No transaction has been sent.
