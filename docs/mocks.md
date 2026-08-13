# mocks.sol

| Mock | Models |
|---|---|
| `mock_luv` | SHAMBA LUV: an ERC-20 with reflections and an optional transfer fee |
| `mock_foreign` | any other token that turns up in the locker by accident |

## `mock_luv.reflect(to, amount)`

The load-bearing function of the whole suite. It raises a holder's balance **with no
transfer and no sender**, which is precisely what an RFI-style token does to a
reflection-included address. Everything the locker calls interest is produced this way.

Modelling reflections as a plain `transfer` into the locker would be wrong in a way that
matters: a transfer has a sender whose balance falls, and it can be intercepted. A
reflection is a balance that simply grows. The locker's entire reward definition —
`balanceOf(this) − total_principal` — only makes sense against the second.

## `mock_luv.set_fee_bps`

Zero by default, because in production the locker **is** fee-exempt. Set to 500 in
`test_DepositCreditsMeasuredDeltaUnderTransferFee` to prove the deposit path is correct
even when that exemption is missing — which is the state the locker is in between
deployment and someone remembering to call `setFeeExemption`.

## `mock_foreign`

Deliberately minimal and deliberately *not* LUV, so `sweep_foreign` has something legal to
move. Its counterpart test asserts the sweep goes to `SURPLUS_SINK` and that the caller
receives nothing, which is what makes a permissionless sweep safe.
