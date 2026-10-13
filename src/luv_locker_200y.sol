// SPDX-License-Identifier: Apache-2.0
// (c) 2026 BANKON / cypherpunk2048 — Apache-2.0
//
// luv_locker_200y — the reflection lock with a 200-year horizon. Holds SHAMBA LUV principal
// under a timelock while the token's reflections accrue to the vault's own balance; each
// depositor's share of that growth is their interest. Principal stays locked. Interest need not.
pragma solidity >=0.8.0;

import {i_erc20_min, safe_token, guarded} from "./in_house.sol";

/**
 * @title  luv_locker_200y
 * @notice Timelocked LUV principal earning reflection interest. No owner, ever.
 *
 * @dev    LINEAGE. Derived from SHAMBA LUV's LUVLocker (live at
 *         0xe07ACAde4bE2bbc264EA702880ed988EBae9B898) and its 2026-08-03 audit. The
 *         reward accounting is the part that audit verified and it is carried across
 *         substantially intact: a staking-pool index at 1e27, reward defined as the
 *         balance nobody has claimed, accrue-then-settle ordering at every mutator,
 *         payouts capped at the real reward balance so a harvest can starve but never
 *         revert-lock and never over-pay.
 *
 *         WHAT CHANGED, AND WHY IT MATTERS MOST. The live vault does two jobs in one
 *         contract: it runs this reflection pool AND it holds generic ERC-20 timelocks,
 *         including the LP token. That forced every reward computation to subtract
 *         `totalAssetLocked[LUV]` and forced `if (token == LUV)` special cases through
 *         eight different functions — the exact shape of bug that survives review. The
 *         generic timelock now lives in its own module (liq-locker), so here the reward
 *         balance is simply `balanceOf(this) - total_principal`. Nothing to special-case
 *         because there is nothing else in the contract. This follows BANKON's standing
 *         rule that folder boundaries are load-bearing and must never be collapsed for
 *         convenience.
 *
 *         NO OWNER. Findings A1 (the owner could extend any depositor's lock), A4 (no
 *         brake) and A5 (single-step ownership) were all findings about an owner, and
 *         there is none here. `lock_duration` is immutable rather than owner-settable;
 *         `extend_lock` is self-only. The owner's `rescue` is replaced by
 *         `sweep_foreign`, which is permissionless, pays to an immutable sink, and
 *         cannot touch LUV at all.
 *
 *         WHY LUV CANNOT BE SWEPT. In liq-locker, surplus is any balance no lock claims,
 *         and sweeping it is safe. Here the balance no depositor claims IS the interest —
 *         it is the reflections in transit. A surplus sweep would be a theft of yield
 *         dressed as housekeeping. So `sweep_foreign` reverts on LUV, unconditionally.
 *         LUV sent here by mistake becomes interest for the depositors. That is the
 *         honest outcome and it is stated rather than discovered.
 *
 *         OPERATIONAL INVARIANT, NOT A CODE PROPERTY. Interest accrues only while this
 *         contract remains reflection-INCLUDED on the LUV token, and deposits/withdrawals
 *         require fee and max-tx exemption. Those are settings on the token, not here.
 *         If the token excludes this contract, interest silently stops accruing and
 *         nothing in this file can detect it. Check it on-chain; do not assume it.
 */
contract luv_locker_200y is guarded {
    using safe_token for address;

    // ------------------------------------------------------------------- errors
    error zero_address();
    error amount_zero();
    error insufficient_principal();
    error time_lock_active();
    error block_lock_active();
    error not_shortenable();
    error duration_too_long();
    error no_rewards();
    error nothing_to_sweep();
    error cannot_sweep_luv();
    error timestamp_overflow();
    error not_fee_exempt();

    // ------------------------------------------------------------------- events
    event deposited(address indexed user, uint256 amount, uint48 unlock_at);
    event withdrawn(address indexed user, uint256 amount);
    event lock_extended(address indexed user, uint48 old_unlock_at, uint48 new_unlock_at);
    event harvested(address indexed user, address indexed payout, uint256 amount);
    event interest_compounded(address indexed user, uint256 amount);
    event interest_mode_set(address indexed user, bool lock_interest);
    event auto_config(address indexed user, uint256 threshold, address payout);
    event poked(address indexed caller, address indexed user, uint256 amount);
    event foreign_swept(address indexed token, address indexed sink, uint256 amount);

    // ---------------------------------------------------------------- constants
    /// @dev 1e27, not 1e18. The index divides by total_principal, and LUV's supply is
    ///      large enough that an 18-decimal index loses meaningful precision on small
    ///      reflection deltas. The extra nine decimals are free here.
    uint256 public constant ACC_SCALE = 1e27;

    /// @dev Two hundred years — the Arweave standard, matching liq-locker (live at
    ///      0x111111f70cb3469B5285862d7a4e7Cb53d04f502). The original luv_locker
    ///      (src/luv_locker.sol) caps locks at a decade, which turns a century-scale guarantee
    ///      into a liveness assumption: someone must survive, keep a key, and remember to roll
    ///      the lock forward twenty times. Two centuries is the longest horizon this house
    ///      already builds to (Arweave's 200-year storage endowment), so a single deposit can
    ///      outlive its depositor. 73,050 days = 200 × 365.25. uint48 seconds overflow in the
    ///      year 8,921,556. Everything else is the original contract, unchanged.
    uint256 public constant MAX_LOCK_DURATION = 73_050 days;

    // --------------------------------------------------------------- immutables
    address public immutable LUV;

    /// @dev Immutable, where the live vault had `setLockDuration`. An owner who can
    ///      change the default lock length for future deposits is a small power, but it
    ///      is still a power, and removing it costs nothing: a different horizon means
    ///      a different deployment.
    uint48 public immutable LOCK_DURATION;

    /// @dev Blocks that must pass after a deposit before withdrawal. Defeats same-block
    ///      deposit/withdraw games against the reward index — enter, absorb a reflection,
    ///      leave, all inside one transaction.
    uint256 public immutable MIN_BLOCK_DELTA;

    /// @notice Destination for non-LUV tokens sent here by mistake. Immutable, which is
    ///         what lets `sweep_foreign` be permissionless.
    address public immutable SURPLUS_SINK;

    // ------------------------------------------------------------------ storage
    struct user_info {
        uint256 principal;
        uint256 reward_debt;
        uint256 accrued;
        uint256 auto_threshold;
        // one packed slot: 160 + 48 + 40 + 8 = 256
        address payout;
        uint48 unlock_at;
        uint40 deposit_block;
        bool lock_interest;
    }

    mapping(address => user_info) public users;

    uint256 public total_principal;
    uint256 public acc_reward_per_principal;
    uint256 public last_reward_balance;

    constructor(address luv_, uint48 lock_duration_, uint256 min_block_delta_, address surplus_sink_) {
        if (luv_ == address(0) || surplus_sink_ == address(0)) revert zero_address();
        if (lock_duration_ == 0 || min_block_delta_ == 0) revert amount_zero();
        if (lock_duration_ > MAX_LOCK_DURATION) revert duration_too_long();
        LUV = luv_;
        LOCK_DURATION = lock_duration_;
        MIN_BLOCK_DELTA = min_block_delta_;
        SURPLUS_SINK = surplus_sink_;
    }

    // ------------------------------------------------------------------ principal
    /**
     * @notice Deposit LUV. Locks for LOCK_DURATION from now.
     * @dev    STATED FOOT-GUN, carried forward from the live vault deliberately: a new
     *         deposit re-locks the ENTIRE principal, not just the new amount. Topping up
     *         a position that matures next week pushes all of it out to a fresh full
     *         term. This is the extend-only culture applied consistently, and the audit
     *         flagged it as intentional-but-unstated. It is now stated. If you want the
     *         old position to mature on schedule, use a second address.
     */
    function deposit(uint256 amount) external non_reentrant {
        if (amount == 0) revert amount_zero();
        _accrue();
        _settle(msg.sender);

        // H-2 (C-1 residual). The cap below separates a mid-deposit reflection from principal
        // only when the transfer is fee-free: with LUV's 5% fee, a 1000 deposit plus a 40
        // reflection arrives as 990 — under `amount`, so a cap would do nothing and the
        // depositor would be credited 40 of other people's interest. A fee and a reflection
        // in the same delta cannot be told apart, so a fee-paying deposit is refused outright.
        // On LUV the exemption is read directly; on a token that does not expose it, an
        // arrival short of `amount` is the evidence of a fee.
        if (!_fee_exempt()) revert not_fee_exempt();
        uint256 before = i_erc20_min(LUV).balanceOf(address(this));
        LUV.safe_transfer_from(msg.sender, address(this), amount);
        uint256 delta = i_erc20_min(LUV).balanceOf(address(this)) - before;
        if (delta < amount) revert not_fee_exempt();

        // C-1 (reflection over-credit). LUV rebases UPWARD during a transfer: it runs
        // _processFees at the TOP of _transfer, distributing a pending reflection to every
        // reflection-included holder — this vault among them — before the tokens move. So
        // the delta can EXCEED `amount` by this vault's share of that reflection. Principal
        // is exactly `amount`; the surplus is interest earned by the principal already here.
        uint256 received = amount;
        uint256 surplus = delta - amount;

        // M-4 (orphaned surplus). Distribute the surplus over the principal that existed when
        // it was earned — BEFORE the new principal joins the base. Distributing it after
        // spread it over a base that included the newcomer, whose debt was then struck at the
        // new index, so the newcomer's slice belonged to nobody and stayed locked forever.
        if (surplus != 0) {
            if (total_principal != 0) acc_reward_per_principal += (surplus * ACC_SCALE) / total_principal;
            last_reward_balance += surplus;
        }
        total_principal += received;
        // Settle the depositor's EXISTING position at the new index, so a top-up keeps its own
        // share of the surplus. total_principal already includes `received`, so the D-1 cap
        // in _settle reads a reward balance that excludes this deposit.
        _settle(msg.sender);

        user_info storage u = users[msg.sender];
        u.principal += received;
        u.deposit_block = uint40(block.number);
        uint48 fresh = _now48() + LOCK_DURATION;
        if (fresh > u.unlock_at) u.unlock_at = fresh;
        u.reward_debt = _mul_acc(u.principal, acc_reward_per_principal);

        _maybe_auto_pay(msg.sender);
        _accrue();
        emit deposited(msg.sender, received, u.unlock_at);
    }

    /// @notice Withdraw matured principal. Both the time lock and the block lock must pass.
    function withdraw(uint256 amount) external non_reentrant {
        user_info storage u = users[msg.sender];
        if (amount == 0) revert amount_zero();
        if (u.principal < amount) revert insufficient_principal();
        if (block.timestamp < u.unlock_at) revert time_lock_active();
        if (block.number < uint256(u.deposit_block) + MIN_BLOCK_DELTA) revert block_lock_active();

        _accrue();
        _settle(msg.sender);
        // Re-checked: _settle may fold interest into principal, never out of it, but a
        // future edit to _settle must not be able to make this stale.
        if (u.principal < amount) revert insufficient_principal();

        _maybe_auto_pay(msg.sender);

        u.principal -= amount;
        total_principal -= amount;
        u.reward_debt = _mul_acc(u.principal, acc_reward_per_principal);

        LUV.safe_transfer(msg.sender, amount);
        _accrue();
        emit withdrawn(msg.sender, amount);
    }

    /**
     * @notice Push your own unlock time later. Never earlier.
     * @dev    AUDIT A1. Self-only. In the live vault the owner could call this on any
     *         depositor and add ten years, repeatedly — a hostage mechanism. There is no
     *         owner here and no third-party path.
     */
    function extend_lock(uint48 new_unlock_at) external {
        user_info storage u = users[msg.sender];
        if (u.principal == 0) revert insufficient_principal();
        if (new_unlock_at <= u.unlock_at) revert not_shortenable();
        if (new_unlock_at > _now48() + uint48(MAX_LOCK_DURATION)) revert duration_too_long();
        emit lock_extended(msg.sender, u.unlock_at, new_unlock_at);
        u.unlock_at = new_unlock_at;
    }

    // ------------------------------------------------------------------- interest
    /// @notice Claim accrued interest. Principal stays locked; interest never is.
    function harvest() external non_reentrant returns (uint256 paid) {
        _accrue();
        _settle(msg.sender);
        paid = _pay_accrued(msg.sender);
        if (paid == 0) revert no_rewards();
        _accrue();
    }

    /**
     * @notice Choose how interest is handled.
     * @param  lock_interest false (default) — interest accrues claimable and principal
     *         stays put. true — interest is folded into locked principal instead, which
     *         grows the position and matures with it.
     * @dev    Settles under the OLD mode first, so switching never reclassifies interest
     *         that has already accrued. Compounding does NOT reset the lock clock.
     */
    function set_interest_mode(bool lock_interest) external non_reentrant {
        _accrue();
        _settle(msg.sender);
        users[msg.sender].lock_interest = lock_interest;
        _accrue();
        emit interest_mode_set(msg.sender, lock_interest);
    }

    /**
     * @notice Auto-pay interest once it reaches `threshold`. Zero disables.
     * @dev    Lets a depositor be paid without ever transacting again — anyone may call
     *         `poke` on their behalf. A locker with a decade-long horizon should not
     *         require its beneficiary to stay liquid enough to claim.
     */
    function set_auto_payout(uint256 threshold, address payout) external non_reentrant {
        _accrue();
        _settle(msg.sender);
        user_info storage u = users[msg.sender];
        u.auto_threshold = threshold;
        u.payout = payout == address(0) ? msg.sender : payout;
        _maybe_auto_pay(msg.sender);
        _accrue();
        emit auto_config(msg.sender, threshold, u.payout);
    }

    /// @notice Keeper entry point: settle `user` and pay them if they are over threshold.
    function poke(address user) external non_reentrant returns (uint256 paid) {
        _accrue();
        _settle(user);
        user_info storage u = users[user];
        if (u.auto_threshold != 0 && u.accrued >= u.auto_threshold) {
            paid = _pay_accrued(user);
        }
        _accrue();
        emit poked(msg.sender, user, paid);
    }

    // -------------------------------------------------------------------- sweep
    /**
     * @notice Send a non-LUV token to SURPLUS_SINK. Callable by anyone.
     * @dev    LUV is refused unconditionally. Unclaimed LUV balance is the reflection
     *         stream, i.e. the depositors' interest — sweeping it would be theft with a
     *         tidy name. There is deliberately no path, privileged or otherwise, that
     *         moves LUV out of this contract except a depositor's own withdraw or harvest.
     */
    function sweep_foreign(address token) external non_reentrant returns (uint256 amount) {
        if (token == LUV) revert cannot_sweep_luv();
        if (token == address(0)) revert zero_address();
        amount = i_erc20_min(token).balanceOf(address(this));
        if (amount == 0) revert nothing_to_sweep();
        token.safe_transfer(SURPLUS_SINK, amount);
        emit foreign_swept(token, SURPLUS_SINK, amount);
    }

    // --------------------------------------------------------------------- views
    /// @notice Interest claimable by `user` right now, including not-yet-accrued reflections.
    function pending_rewards(address user) external view when_not_entered returns (uint256) {
        user_info storage u = users[user];
        uint256 acc = acc_reward_per_principal;
        uint256 current = _reward_balance();
        if (total_principal != 0 && current > last_reward_balance) {
            acc += ((current - last_reward_balance) * ACC_SCALE) / total_principal;
        }
        uint256 pending;
        if (u.principal != 0) {
            uint256 accumulated = _mul_acc(u.principal, acc);
            if (accumulated > u.reward_debt) pending = accumulated - u.reward_debt;
        }
        // In compound mode pending interest becomes principal, never a claim.
        if (u.lock_interest) return u.accrued;
        return u.accrued + pending;
    }

    /// @notice True while either the time lock or the block lock still holds.
    function is_locked(address user) external view when_not_entered returns (bool) {
        user_info storage u = users[user];
        if (u.principal == 0) return false;
        return block.timestamp < u.unlock_at || block.number < uint256(u.deposit_block) + MIN_BLOCK_DELTA;
    }

    /// @notice The undistributed reflection balance — the pool interest is paid from.
    function reward_balance() external view when_not_entered returns (uint256) {
        return _reward_balance();
    }

    // ----------------------------------------------------------------- internals
    /// @dev Everything above principal is reward. With generic asset locks moved to
    ///      their own module there is nothing else this contract holds, so this is the
    ///      whole definition — no subtractions, no token identity checks.
    function _reward_balance() internal view returns (uint256) {
        uint256 bal = i_erc20_min(LUV).balanceOf(address(this));
        return bal > total_principal ? bal - total_principal : 0;
    }

    /// @dev Fold any balance growth since the last look into the index.
    function _accrue() internal {
        uint256 current = _reward_balance();
        if (total_principal != 0 && current > last_reward_balance) {
            acc_reward_per_principal += ((current - last_reward_balance) * ACC_SCALE) / total_principal;
        }
        last_reward_balance = current;
    }

    /// @dev Move this user from the index into their own accrued or principal bucket.
    function _settle(address user) internal {
        user_info storage u = users[user];
        if (u.principal == 0) {
            u.reward_debt = 0;
            return;
        }
        uint256 accumulated = _mul_acc(u.principal, acc_reward_per_principal);
        if (accumulated > u.reward_debt) {
            uint256 pending = accumulated - u.reward_debt;
            if (u.lock_interest) {
                // D-1. Compounding moves interest from the reward side into principal, so it
                // must never move more than the reward side actually holds. The index is a
                // scaled approximation accumulated across changing values of total_principal,
                // and it can value a share one wei above the balance backing it; writing that
                // wei into total_principal broke `balance >= total_principal` and left the
                // LAST withdrawer unable to take their final wei out — no owner, no rescue,
                // and total_principal could never return to zero. Found by the stateful
                // fuzzer (test/luv_locker_invariant.t.sol) and pinned by
                // test/luv_locker_dust.t.sol. The capped remainder is at most dust and stays
                // on the reward side, where it benefits every depositor rather than one.
                uint256 avail = _reward_balance();
                if (pending > avail) pending = avail;
                if (pending == 0) { u.reward_debt = accumulated; return; }
                u.principal += pending;
                total_principal += pending;
                // Recompute against the grown principal, or the next settle pays twice.
                accumulated = _mul_acc(u.principal, acc_reward_per_principal);
                emit interest_compounded(user, pending);
            } else {
                u.accrued += pending;
            }
        }
        u.reward_debt = accumulated;
    }

    function _maybe_auto_pay(address user) internal {
        user_info storage u = users[user];
        if (u.auto_threshold != 0 && u.accrued >= u.auto_threshold) _pay_accrued(user);
    }

    /// @dev Capped at the real reward balance. A payout can come up short — that is a
    ///      starved harvest, retryable — but it can never revert-lock the contract or
    ///      pay out principal belonging to somebody else.
    function _pay_accrued(address user) internal returns (uint256 paid) {
        user_info storage u = users[user];
        uint256 amount = u.accrued;
        if (amount == 0) return 0;

        uint256 available = _reward_balance();
        if (amount > available) amount = available;
        if (amount == 0) return 0;

        address to = u.payout == address(0) ? user : u.payout;
        u.accrued -= amount;
        LUV.safe_transfer(to, amount);
        emit harvested(user, to, amount);
        return amount;
    }

    // NOTE (M-3). There is deliberately no bare "sync last_reward_balance to the current
    // balance" helper. Every mutator ends with _accrue() instead: LUV rebases up during the
    // vault's own outgoing transfers (withdraw/harvest/auto-pay all run _processFees at the
    // top of _transfer), so a reflection can land mid-call. _accrue() distributes that growth
    // to the index; a plain resync would overwrite it and orphan the reflection forever.
    // _accrue() is identical to a resync whenever nothing grew, so it is strictly safer.

    /**
     * @dev H-1 (index inflation → permanent deposit DoS). `principal * acc` overflowed once
     *      the index was inflated: deposit 1 wei into an empty vault, send it 1e30 straight,
     *      harvest the donation back (net cost 1 wei), and `acc` stands at 1e57 — after which
     *      every deposit above ~116 LUV reverted in its debt line, forever, with no owner to
     *      reset it. This computes floor(a * b / ACC_SCALE) exactly without the intermediate
     *      product: with a = ah*S + al and b = bh*S + bl (S = ACC_SCALE),
     *          a*b/S = ah*bh*S + ah*bl + al*bh + floor(al*bl / S)
     *      where every other term is an integer, so the floor is exact. al, bl < 1e27 keeps
     *      al*bl < 1e54. It reverts only when the true RESULT exceeds uint256, which an index
     *      bounded by the token's supply cannot reach. Identical to the old expression on
     *      every input that did not overflow.
     */
    function _mul_acc(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 ah = a / ACC_SCALE;
        uint256 al = a % ACC_SCALE;
        uint256 bh = b / ACC_SCALE;
        uint256 bl = b % ACC_SCALE;
        return ah * bh * ACC_SCALE + ah * bl + al * bh + (al * bl) / ACC_SCALE;
    }

    /// @dev LUV exposes isExcludedFromFee(address). A token that does not answers nothing,
    ///      and the arrival check in deposit stands in for it.
    function _fee_exempt() internal view returns (bool) {
        (bool ok, bytes memory ret) =
            LUV.staticcall(abi.encodeWithSignature("isExcludedFromFee(address)", address(this)));
        if (!ok || ret.length < 32) return true;
        return abi.decode(ret, (bool));
    }

    function _now48() internal view returns (uint48) {
        if (block.timestamp > type(uint48).max) revert timestamp_overflow();
        return uint48(block.timestamp);
    }
}
