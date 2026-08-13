# deploy.s.sol

Deploys the reflection lock. One contract, four immutable arguments.

## Environment

| Variable | Meaning |
|---|---|
| `LUV_TOKEN` | the token this locker holds, forever |
| `LOCK_DURATION` | seconds, immutable — the live vault had `setLockDuration`, this does not |
| `MIN_BLOCK_DELTA` | blocks between deposit and withdrawal; set above realistic reorg depth |
| `SURPLUS_SINK` | where *foreign* tokens go when swept. Never receives LUV |

```sh
make fork
make deploy
```

## The part that is not in this repository

The script prints these on completion because deployment is not the last step:

```
LUV.setFeeExemption(locker, true)      # deposits/withdrawals must not pay the buy/sell fee
LUV.setMaxTxExemption(locker, true)    # nor hit the max-tx cap
```

**And never exclude the locker from reflections.** The reflections landing on the
contract's balance *are* the interest.

If any of these is wrong, the locker still compiles, deploys, and accepts deposits — and
quietly earns nothing. Nothing reverts, no event fires, and no code in this repository can
detect it. Verify on-chain after deployment and after any change to the token.
`usage.md` §2 has the calls.

## Nothing here is reversible

No setters. A wrong `LOCK_DURATION` means a redeployment, not a correction.
