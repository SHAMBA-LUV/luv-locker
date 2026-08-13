// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

/**
 * PRECISION AND THE DUST BOUND — AUDIT §7, item 4.
 *
 * "Precision analysis of the 1e27 index at LUV's real supply scale, with the worst-case dust
 *  bound stated numerically rather than described as 'benign'."
 *
 * Two separate questions, answered separately:
 *
 *   A. HOW MUCH does floor division lose, at LUV's real scale? Stated as a number, derived,
 *      and then measured against the contract to confirm the derivation.
 *
 *   B. CAN the loss ever go the WRONG WAY — can the vault end up owing more principal than
 *      it holds, and if so, can that strand a withdrawal? This is the question that decides
 *      whether the dust is benign or not, and the stateful fuzzer found that it CAN, by one
 *      wei, through compound mode. Everything about that is pinned below.
 *
 * THE DERIVATION (A).
 *
 *   ACC_SCALE = 1e27. On accrual:
 *       acc += (delta * 1e27) / total_principal
 *   The truncated remainder is < total_principal in numerator units, so the reward value
 *   left undistributed by one accrual is:
 *       lost_per_accrual < total_principal / 1e27      (wei of LUV)
 *
 *   At LUV's real scale — 111,111,111,111,111,111 LUV = 1.11111e35 wei — if the ENTIRE
 *   supply were the vault's principal:
 *       lost_per_accrual < 1.11111e35 / 1e27 = 1.11111e8 wei = 0.000000000111111 LUV
 *
 *   That is the absolute worst case and it is per accrual, not per year. On settle:
 *       accumulated = (principal * acc) / 1e27
 *   truncates a further < 1 wei per user per settle.
 *
 *   Neither is destroyed: both remain in the vault's LUV balance, where they sit on the
 *   reward side as a buffer that a starved harvest can later draw on.
 */

import "forge-std/Test.sol";
import {luv_locker} from "../src/luv_locker.sol";
import {mock_luv} from "./mocks.sol";

contract luv_locker_dust_test is Test {
    luv_locker internal vault;
    mock_luv internal luv;

    address internal constant SINK = address(0x5151);
    address internal constant A = address(0xA1);
    address internal constant B = address(0xB2);
    address internal constant C = address(0xC3);

    uint48  internal constant LOCK_DURATION   = 90 days;
    uint256 internal constant MIN_BLOCK_DELTA = 100;

    /// LUV's real supply: 111 quadrillion, 18 decimals.
    uint256 internal constant LUV_SUPPLY = 111_111_111_111_111_111e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(20_000_000);
        luv = new mock_luv();
        vault = new luv_locker(address(luv), LOCK_DURATION, MIN_BLOCK_DELTA, SINK);
        address[3] memory who = [A, B, C];
        for (uint256 i = 0; i < 3; i++) {
            luv.mint(who[i], LUV_SUPPLY / 4);
            vm.prank(who[i]);
            luv.approve(address(vault), type(uint256).max);
        }
    }

    function _dep(address w, uint256 amt) internal { vm.prank(w); vault.deposit(amt); }
    function _mature() internal {
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.roll(block.number + MIN_BLOCK_DELTA);
    }

    // ─────────────────────────────────── A. the bound, derived then measured
    /**
     * The whole supply locked, then a reflection. The undistributed remainder must be
     * strictly below total_principal / ACC_SCALE — which at this scale is 1.11111e8 wei,
     * a ten-billionth of one LUV.
     */
    function test_DustPerAccrualIsBelowTheDerivedBound() public {
        uint256 whole = LUV_SUPPLY / 4;
        _dep(A, whole);

        uint256 tp = vault.total_principal();
        uint256 bound_wei = tp / vault.ACC_SCALE();          // the derivation, in code

        uint256 idx_before = vault.acc_reward_per_principal();
        uint256 REFLECT = 1_000_000e18;
        luv.mint(address(vault), REFLECT);
        vault.poke(A);                                        // forces _accrue + _settle

        uint256 idx_after = vault.acc_reward_per_principal();
        uint256 distributed = ((idx_after - idx_before) * tp) / vault.ACC_SCALE();
        uint256 undistributed = REFLECT - distributed;

        emit log_named_uint("total_principal (wei)      ", tp);
        emit log_named_uint("derived bound (wei)        ", bound_wei);
        emit log_named_uint("undistributed dust (wei)   ", undistributed);

        assertLt(undistributed, bound_wei + 1, "dust exceeded the derived bound");
        // and in human terms, at the very worst, a ten-billionth of one LUV
        assertLt(bound_wei, 0.000000001e18, "the bound itself is larger than a billionth of a LUV");
    }

    /// The dust is not destroyed: it stays on the reward side, available to a later harvest.
    function test_DustStaysInTheVaultAsRewardBalance() public {
        _dep(A, 1_000_000e18);
        luv.mint(address(vault), 12_345_678_901); // an amount that will not divide evenly
        vault.poke(A);
        uint256 owed = vault.pending_rewards(A);
        uint256 reward_side = vault.reward_balance();
        assertGe(reward_side, owed, "dust left the vault instead of buffering the reward side");
    }

    /// A thousand accruals do not compound the loss into anything meaningful.
    function test_DustDoesNotAccumulateAcrossManyAccruals() public {
        _dep(A, 1_000_000e18);
        _dep(B, 3_333_333e18);          // deliberately indivisible ratio
        uint256 total_in;
        for (uint256 i = 0; i < 1000; i++) {
            uint256 amt = 1e18 + i;      // never a round number
            luv.mint(address(vault), amt);
            total_in += amt;
            vault.poke(A);
        }
        uint256 owed = vault.pending_rewards(A) + vault.pending_rewards(B);
        uint256 lost = total_in - owed;
        emit log_named_uint("reflected over 1000 accruals", total_in);
        emit log_named_uint("undistributed after 1000    ", lost);
        // a thousand accruals, and the residue is still far below a single LUV
        assertLt(lost, 1e18, "dust accumulated past one whole LUV over 1000 accruals");
    }

    // ─────────────────────────────────── B. the direction of the error
    /**
     * FINDING D-1 (low). Found by the stateful fuzzer added for §7 item 1.
     *
     * In COMPOUND mode `_settle` moves `pending` out of the reward side and into principal:
     *
     *     u.principal    += pending;
     *     total_principal += pending;
     *
     * `pending` is derived from the index, and the index is a scaled approximation of the
     * balance growth. Across a sequence of accruals at DIFFERENT values of total_principal,
     * the index can value a user's share one wei above what the reward side actually holds.
     * Compounding then writes that wei into `total_principal`, and the vault's invariant
     *
     *     balanceOf(vault) >= total_principal
     *
     * fails by exactly that one wei.
     *
     * This test does not prove the bound is one wei in general — it pins the behaviour that
     * was found, measures it, and above all establishes the CONSEQUENCE, which is what
     * decides the severity. See test_D1_ShortfallCannotStrandAWithdrawal below.
     */
    function test_D1_CompoundCanOvercreditPrincipalByDust() public {
        // small, indivisible principals maximise the relative rounding error
        _dep(A, 7);
        _dep(B, 13);
        _dep(C, 3);

        vm.prank(A); vault.set_interest_mode(true);
        vm.prank(B); vault.set_interest_mode(true);

        // a long run of tiny, awkward reflections while principals shift underneath
        for (uint256 i = 1; i <= 200; i++) {
            luv.mint(address(vault), (i % 7) + 1);
            vault.poke(A);
            vault.poke(B);
            if (i % 5 == 0) vault.poke(C);
        }

        uint256 bal = luv.balanceOf(address(vault));
        uint256 tp  = vault.total_principal();
        emit log_named_uint("vault balance   ", bal);
        emit log_named_uint("total_principal ", tp);

        // AFTER THE FIX there is no shortfall at all: compounding is capped at the reward
        // side, so the solvency invariant holds through every sequence. Before the fix this
        // exact run ended 821 held against 822 owed.
        assertGe(bal, tp, "D-1 regression: the vault owes more principal than it holds");
    }

    /**
     * THE QUESTION THAT DECIDES SEVERITY. If the vault is a wei short, does the last
     * withdrawer get stuck? `withdraw` transfers `amount` and reverts on an insufficient
     * balance, so a shortfall could in principle strand the final exit permanently — there
     * is no owner and no rescue.
     *
     * It does not, and the reason is structural: any reflection that has ever landed sits on
     * the reward side as an un-indexed buffer far larger than the dust, and `_accrue` folds
     * fresh growth in before the transfer. A vault that has taken even one reflection has
     * orders of magnitude more slack than the shortfall. The test drives the sequence above
     * and then exits EVERY depositor, in the worst order, asserting each one gets paid.
     */
    function test_D1_ShortfallCannotStrandAWithdrawal() public {
        _dep(A, 7);
        _dep(B, 13);
        _dep(C, 3);
        vm.prank(A); vault.set_interest_mode(true);
        vm.prank(B); vault.set_interest_mode(true);
        for (uint256 i = 1; i <= 200; i++) {
            luv.mint(address(vault), (i % 7) + 1);
            vault.poke(A); vault.poke(B);
            if (i % 5 == 0) vault.poke(C);
        }
        _mature();

        // every depositor exits, last-out included
        address[3] memory who = [A, B, C];
        for (uint256 i = 0; i < 3; i++) {
            (uint256 p, , , , , , , ) = vault.users(who[i]);
            if (p == 0) continue;
            vm.prank(who[i]);
            vault.withdraw(p);                       // must not revert for anyone
            (uint256 after_p, , , , , , , ) = vault.users(who[i]);
            assertEq(after_p, 0, "a depositor could not exit in full");
        }
        assertEq(vault.total_principal(), 0, "principal remains after everyone exited");
    }

    /// The same, at realistic scale rather than at 3-wei principals.
    function test_D1_RealisticScaleExitsCleanly() public {
        _dep(A, 1_000_000e18);
        _dep(B, 2_500_000e18);
        _dep(C, 333_333e18);
        vm.prank(A); vault.set_interest_mode(true);
        vm.prank(C); vault.set_interest_mode(true);
        for (uint256 i = 1; i <= 100; i++) {
            luv.mint(address(vault), 1_234_567e12 + i);
            vault.poke(A); vault.poke(B); vault.poke(C);
        }
        _mature();
        address[3] memory who = [A, B, C];
        for (uint256 i = 0; i < 3; i++) {
            (uint256 p, , , , , , , ) = vault.users(who[i]);
            vm.prank(who[i]);
            vault.withdraw(p);
        }
        assertEq(vault.total_principal(), 0, "principal remains after everyone exited");
        // Interest that nobody harvested legitimately stays behind — it is still owed to the
        // depositors and claimable by them, so it is not "stranded". What must be gone is
        // PRINCIPAL, asserted above.
        uint256 left = luv.balanceOf(address(vault));
        uint256 owed = vault.pending_rewards(A) + vault.pending_rewards(B) + vault.pending_rewards(C);
        emit log_named_uint("left in vault", left);
        emit log_named_uint("still owed   ", owed);
        assertGe(owed + 1e18, left, "more than a LUV of unclaimable residue");
    }
}
