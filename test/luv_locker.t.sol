// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TimeBase} from "./time_base.sol";
import {luv_locker} from "../src/luv_locker.sol";
import {mock_luv, mock_foreign} from "./mocks.sol";

contract luv_locker_test is TimeBase {
    luv_locker internal V;
    mock_luv internal luv;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal keeper = address(0x9EE9);
    address internal sink = address(0x5142);

    uint48 internal constant LOCK = 365 days;
    uint256 internal constant BLOCKS = 10;

    function setUp() public {
        _startClock(1_800_000_000);
        vm.roll(1_000_000);
        luv = new mock_luv();
        V = new luv_locker(address(luv), LOCK, BLOCKS, sink);

        luv.mint(alice, 1_000_000 ether);
        luv.mint(bob, 1_000_000 ether);
        vm.prank(alice);
        luv.approve(address(V), type(uint256).max);
        vm.prank(bob);
        luv.approve(address(V), type(uint256).max);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.prank(who);
        V.deposit(amount);
    }

    function _mature() internal {
        _advance(LOCK);
        vm.roll(block.number + BLOCKS);
    }

    // ------------------------------------------------------------------ principal
    function test_DepositThenWithdrawAtMaturity() public {
        _deposit(alice, 1_000 ether);
        assertEq(V.total_principal(), 1_000 ether);
        assertTrue(V.is_locked(alice));

        _mature();
        vm.prank(alice);
        V.withdraw(1_000 ether);

        assertEq(V.total_principal(), 0);
        assertEq(luv.balanceOf(alice), 1_000_000 ether);
    }

    function test_CannotWithdrawBeforeTimeLock() public {
        _deposit(alice, 1_000 ether);
        vm.roll(block.number + BLOCKS);
        vm.prank(alice);
        vm.expectRevert(luv_locker.time_lock_active.selector);
        V.withdraw(1_000 ether);
    }

    /// The block lock exists to defeat enter/absorb-a-reflection/leave inside one
    /// transaction. Time alone is not enough.
    function test_BlockLockHoldsEvenAfterTimeLockPasses() public {
        _deposit(alice, 1_000 ether);
        _advance(LOCK); // time satisfied, blocks not
        vm.prank(alice);
        vm.expectRevert(luv_locker.block_lock_active.selector);
        V.withdraw(1_000 ether);
    }

    // -------------------------------------------------------------------- interest
    function test_ReflectionsBecomeClaimableInterest() public {
        _deposit(alice, 1_000 ether);
        luv.reflect(address(V), 100 ether); // a reflection lands on the vault

        assertEq(V.pending_rewards(alice), 100 ether);

        vm.prank(alice);
        uint256 paid = V.harvest();
        assertEq(paid, 100 ether);
        assertEq(luv.balanceOf(alice), 999_000 ether + 100 ether);
        // Principal is untouched and still locked.
        assertEq(V.total_principal(), 1_000 ether);
        assertTrue(V.is_locked(alice));
    }

    function test_TwoDepositorsSplitReflectionsProRata() public {
        _deposit(alice, 1_000 ether);
        _deposit(bob, 3_000 ether);
        luv.reflect(address(V), 400 ether);

        assertApproxEqAbs(V.pending_rewards(alice), 100 ether, 1, "1/4 of the pool");
        assertApproxEqAbs(V.pending_rewards(bob), 300 ether, 1, "3/4 of the pool");
    }

    /// A depositor who joins after a reflection must not be paid for it.
    function test_LateDepositorEarnsNothingFromEarlierReflections() public {
        _deposit(alice, 1_000 ether);
        luv.reflect(address(V), 100 ether);
        _deposit(bob, 1_000 ether);

        assertEq(V.pending_rewards(bob), 0, "bob was not here for that reflection");
        assertApproxEqAbs(V.pending_rewards(alice), 100 ether, 1);
    }

    function test_CompoundModeFoldsInterestIntoLockedPrincipal() public {
        _deposit(alice, 1_000 ether);
        vm.prank(alice);
        V.set_interest_mode(true);

        luv.reflect(address(V), 100 ether);
        vm.prank(alice);
        V.poke(alice); // settles under compound mode

        (uint256 principal,,,,,,,) = V.users(alice);
        assertEq(principal, 1_100 ether, "interest became principal");
        assertEq(V.total_principal(), 1_100 ether);
        assertEq(V.pending_rewards(alice), 0, "nothing claimable in compound mode");
    }

    function test_CompoundingDoesNotResetTheLockClock() public {
        _deposit(alice, 1_000 ether);
        vm.prank(alice);
        V.set_interest_mode(true);
        (,,,,, uint48 unlock_before,,) = V.users(alice);

        _advance(LOCK / 2);
        luv.reflect(address(V), 100 ether);
        V.poke(alice);

        (,,,,, uint48 unlock_after,,) = V.users(alice);
        assertEq(unlock_after, unlock_before, "compounding must not extend the lock");
    }

    /// Harvests can starve — that is safe. They must never revert-lock the vault or
    /// pay out somebody else's principal.
    function test_HarvestNeverPaysOutOfPrincipal() public {
        _deposit(alice, 1_000 ether);
        _deposit(bob, 1_000 ether);
        luv.reflect(address(V), 100 ether);

        vm.prank(alice);
        V.harvest();
        vm.prank(bob);
        V.harvest();

        assertGe(luv.balanceOf(address(V)), V.total_principal(), "principal still fully backed");
    }

    function test_HarvestWithNothingAccruedReverts() public {
        _deposit(alice, 1_000 ether);
        vm.prank(alice);
        vm.expectRevert(luv_locker.no_rewards.selector);
        V.harvest();
    }

    // ------------------------------------------------------------- auto payout
    function test_AutoPayoutFiresOnPoke() public {
        _deposit(alice, 1_000 ether);
        vm.prank(alice);
        V.set_auto_payout(50 ether, bob); // pay to bob once 50 accrues

        luv.reflect(address(V), 100 ether);
        uint256 bob_before = luv.balanceOf(bob);

        vm.prank(keeper); // anyone may poke
        uint256 paid = V.poke(alice);

        assertEq(paid, 100 ether);
        assertEq(luv.balanceOf(bob), bob_before + 100 ether, "paid to the nominated address");
        assertEq(luv.balanceOf(keeper), 0, "the keeper earns nothing");
    }

    function test_PokeBelowThresholdPaysNothing() public {
        _deposit(alice, 1_000 ether);
        vm.prank(alice);
        V.set_auto_payout(500 ether, alice);
        luv.reflect(address(V), 100 ether);

        vm.prank(keeper);
        assertEq(V.poke(alice), 0);
    }

    // ------------------------------------------------- AUDIT A1: no owner, self-only
    /// In the live vault the owner could extend any depositor's unlock time by ten
    /// years, repeatedly. There is no owner here and `extend_lock` acts only on the
    /// caller's own position — there is no argument for whose lock to extend.
    function test_A1_ExtendActsOnlyOnTheCallersOwnLock() public {
        _deposit(alice, 1_000 ether);
        (,,,,, uint48 alice_unlock,,) = V.users(alice);

        vm.prank(bob);
        vm.expectRevert(luv_locker.insufficient_principal.selector);
        V.extend_lock(alice_unlock + 1 days); // bob has no position to extend

        (,,,,, uint48 after_unlock,,) = V.users(alice);
        assertEq(after_unlock, alice_unlock, "alice's lock is unreachable by bob");
    }

    function test_ExtendLockNeverShortens() public {
        _deposit(alice, 1_000 ether);
        (,,,,, uint48 unlock_at,,) = V.users(alice);
        vm.prank(alice);
        vm.expectRevert(luv_locker.not_shortenable.selector);
        V.extend_lock(unlock_at - 1);
    }

    /// Stated foot-gun, carried forward deliberately: a top-up re-locks EVERYTHING.
    function test_DepositRelocksTheEntirePrincipal() public {
        _deposit(alice, 1_000 ether);
        _advance(LOCK - 1 days); // one day from maturity

        _deposit(alice, 1 ether); // a small top-up
        vm.roll(block.number + BLOCKS);
        _advance(1 days); // the ORIGINAL maturity passes

        vm.prank(alice);
        vm.expectRevert(luv_locker.time_lock_active.selector);
        V.withdraw(1_000 ether);
    }

    // ----------------------------------------------------------------- fee tokens
    /// H-2: a fee-paying deposit is refused. A fee and a mid-deposit reflection in one
    /// balance delta cannot be told apart, so crediting either way can misassign interest.
    function test_DepositRefusedUnderTransferFee() public {
        luv.set_fee_bps(500); // 5%, i.e. the locker is NOT fee-exempt
        vm.prank(alice);
        vm.expectRevert(luv_locker.not_fee_exempt.selector);
        V.deposit(1_000 ether);
        assertEq(V.total_principal(), 0);
        assertEq(luv.balanceOf(address(V)), 0, "the revert returns the tokens");
    }

    // --------------------------------------------------------------------- sweeps
    /// The asymmetry with liq-locker, and the whole reason it exists: here the
    /// unclaimed balance IS the depositors' interest. Sweeping it would be theft.
    function test_LuvCanNeverBeSwept() public {
        _deposit(alice, 1_000 ether);
        luv.reflect(address(V), 500 ether);

        vm.prank(address(this)); // the deployer, the most privileged address there is
        vm.expectRevert(luv_locker.cannot_sweep_luv.selector);
        V.sweep_foreign(address(luv));

        assertEq(V.pending_rewards(alice), 500 ether, "interest intact");
    }

    function test_ForeignTokenSweepsToTheImmutableSink() public {
        mock_foreign junk = new mock_foreign();
        junk.mint(address(V), 777 ether);

        vm.prank(keeper); // permissionless
        uint256 swept = V.sweep_foreign(address(junk));

        assertEq(swept, 777 ether);
        assertEq(junk.balanceOf(sink), 777 ether, "destination is immutable, not the caller");
        assertEq(junk.balanceOf(keeper), 0);
    }

    function test_SweepWithNothingThereReverts() public {
        mock_foreign junk = new mock_foreign();
        vm.expectRevert(luv_locker.nothing_to_sweep.selector);
        V.sweep_foreign(address(junk));
    }

    // ------------------------------------------------------------------ deploy bounds
    function test_ConstructorRejectsBadArguments() public {
        vm.expectRevert(luv_locker.zero_address.selector);
        new luv_locker(address(0), LOCK, BLOCKS, sink);

        vm.expectRevert(luv_locker.zero_address.selector);
        new luv_locker(address(luv), LOCK, BLOCKS, address(0));

        vm.expectRevert(luv_locker.amount_zero.selector);
        new luv_locker(address(luv), 0, BLOCKS, sink);

        uint48 too_long = uint48(V.MAX_LOCK_DURATION()) + 1; // hoisted: AUDIT T-2
        vm.expectRevert(luv_locker.duration_too_long.selector);
        new luv_locker(address(luv), too_long, BLOCKS, sink);
    }

    // ------------------------------------------------------------------------ fuzz
    /// The solvency invariant. If the vault's balance ever falls below the principal
    /// it claims to hold, somebody cannot withdraw. Nothing else matters more.
    function testFuzz_BalanceAlwaysCoversPrincipal(
        uint96[6] calldata deposits,
        uint96[6] calldata reflections
    ) public {
        for (uint256 i; i < 6; ++i) {
            uint256 amount = uint256(deposits[i]) + 1 ether;
            address who = i % 2 == 0 ? alice : bob;
            if (amount > luv.balanceOf(who)) continue;

            _deposit(who, amount);
            luv.reflect(address(V), uint256(reflections[i]));
            V.poke(who);

            assertGe(
                luv.balanceOf(address(V)), V.total_principal(), "principal must stay fully backed"
            );
        }
    }

    function testFuzz_PendingRewardsNeverExceedRewardBalance(uint96 deposit_amt, uint96 reflect_amt)
        public
    {
        uint256 amount = uint256(deposit_amt) + 1 ether;
        vm.assume(amount <= luv.balanceOf(alice));
        _deposit(alice, amount);
        luv.reflect(address(V), reflect_amt);

        assertLe(
            V.pending_rewards(alice), V.reward_balance(), "cannot promise more than is there"
        );
    }
}
