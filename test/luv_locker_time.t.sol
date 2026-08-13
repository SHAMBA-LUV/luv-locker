// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TimeBase} from "./time_base.sol";
import {luv_locker} from "../src/luv_locker.sol";
import {mock_luv} from "./mocks.sol";

/**
 * Time-focused suite for luv_locker: maturity boundaries to the second, extension across
 * elapsed time, the ten-year horizon, re-lock-on-deposit over time, and the block-lock /
 * time-lock interplay. All time moves through the absolute cursor in TimeBase (AUDIT T-1:
 * never chain vm.warp(block.timestamp + X) under via_ir).
 */
contract luv_locker_time_test is TimeBase {
    luv_locker internal V;
    mock_luv internal luv;

    address internal alice = address(0xA11CE);
    address internal sink = address(0x5142);

    uint48 internal constant LOCK = 365 days;
    uint256 internal constant BLOCKS = 10;

    function setUp() public {
        _startClock(1_800_000_000);
        vm.roll(1_000_000);
        luv = new mock_luv();
        V = new luv_locker(address(luv), LOCK, BLOCKS, sink);
        luv.mint(alice, 10_000_000 ether);
        vm.prank(alice);
        luv.approve(address(V), type(uint256).max);
    }

    function _deposit(uint256 amt) internal { vm.prank(alice); V.deposit(amt); }

    // ── maturity boundary, to the second ──
    function test_WithdrawRevertsOneSecondBeforeMaturity() public {
        _deposit(1_000 ether);
        vm.roll(block.number + BLOCKS); // satisfy the block lock so only time is under test
        _advance(uint256(LOCK) - 1);    // one second short
        vm.prank(alice);
        vm.expectRevert(luv_locker.time_lock_active.selector);
        V.withdraw(1_000 ether);
    }

    function test_WithdrawSucceedsExactlyAtMaturity() public {
        _deposit(1_000 ether);
        vm.roll(block.number + BLOCKS);
        _advance(uint256(LOCK)); // exactly at unlock_at: block.timestamp == unlock_at, and the
                                 // guard is `block.timestamp < unlock_at`, so this must pass
        vm.prank(alice);
        V.withdraw(1_000 ether);
        assertEq(V.total_principal(), 0);
    }

    // ── extend across elapsed time ──
    function test_ExtendPartwayThroughPushesMaturityOut() public {
        _deposit(1_000 ether);
        (,,,,, uint48 unlock0,,) = V.users(alice);

        _advance(200 days); // partway through the original year
        uint48 newUnlock = uint48(block.timestamp) + 300 days;
        vm.prank(alice);
        V.extend_lock(newUnlock);

        // original maturity would have been reached at +365d; advance there and confirm still locked
        vm.roll(block.number + BLOCKS);
        _advance(165 days); // now at the ORIGINAL unlock moment (200 + 165 = 365)
        assertGt(block.timestamp, uint256(unlock0) - 1); // we are at/after the old unlock
        vm.prank(alice);
        vm.expectRevert(luv_locker.time_lock_active.selector);
        V.withdraw(1_000 ether);

        // advance to the NEW unlock and it opens
        _advance(uint256(newUnlock) - block.timestamp);
        vm.prank(alice);
        V.withdraw(1_000 ether);
        assertEq(V.total_principal(), 0);
    }

    function test_ExtendCannotShortenEvenAfterTimePasses() public {
        _deposit(1_000 ether);
        (,,,,, uint48 unlock0,,) = V.users(alice);
        _advance(100 days);
        vm.prank(alice);
        vm.expectRevert(luv_locker.not_shortenable.selector);
        V.extend_lock(unlock0 - 1);
    }

    function test_ExtendRejectsBeyondTenYearHorizon() public {
        _deposit(1_000 ether);
        uint256 maxDur = V.MAX_LOCK_DURATION();
        uint48 tooFar = uint48(block.timestamp + maxDur + 1);
        vm.prank(alice);
        vm.expectRevert(luv_locker.duration_too_long.selector);
        V.extend_lock(tooFar);
    }

    // ── the full ten-year horizon actually works end to end ──
    function test_TenYearMaxHorizonLockAndWithdraw() public {
        uint256 maxDur = V.MAX_LOCK_DURATION(); // 3650 days
        // deposit, then extend to the maximum horizon from now
        _deposit(2_000 ether);
        uint48 farUnlock = uint48(block.timestamp + maxDur);
        vm.prank(alice);
        V.extend_lock(farUnlock);

        // one second before the decade is up: still locked
        vm.roll(block.number + BLOCKS);
        _advance(maxDur - 1);
        vm.prank(alice);
        vm.expectRevert(luv_locker.time_lock_active.selector);
        V.withdraw(2_000 ether);

        // at the decade: opens
        _advance(1);
        vm.prank(alice);
        V.withdraw(2_000 ether);
        assertEq(V.total_principal(), 0);
    }

    // ── a top-up re-locks the ENTIRE principal to a fresh full term ──
    function test_DepositRelocksEntirePrincipalOverTime() public {
        _deposit(1_000 ether);
        _advance(360 days); // almost matured
        _deposit(1 ether);  // tiny top-up re-locks all 1001 to now + 365d

        vm.roll(block.number + BLOCKS);
        _advance(5 days); // this is 365 days after the FIRST deposit — the old maturity
        vm.prank(alice);
        vm.expectRevert(luv_locker.time_lock_active.selector); // but the re-lock still holds
        V.withdraw(1_000 ether);

        _advance(uint256(LOCK) - 5 days); // reach the new full term
        vm.prank(alice);
        V.withdraw(1_001 ether);
        assertEq(V.total_principal(), 0);
    }

    // ── compounding interest over years must not reset the lock clock ──
    function test_CompoundingOverYearsDoesNotResetClock() public {
        _deposit(1_000 ether);
        (,,,,, uint48 unlock0,,) = V.users(alice);

        vm.prank(alice);
        V.set_interest_mode(true); // compound

        // reflections land and get compounded at intervals over the year
        for (uint256 i = 0; i < 3; i++) {
            luv.reflect(address(V), 50 ether);
            _advance(90 days);
            vm.prank(alice);
            V.poke(alice); // settle → compounds into principal
        }
        // the unlock time must be unchanged by compounding
        (,,,,, uint48 unlockNow,,) = V.users(alice);
        assertEq(unlockNow, unlock0, "compounding moved the lock clock");

        // and once the original term elapses, the grown principal is withdrawable
        vm.roll(block.number + BLOCKS);
        _advance(uint256(unlock0) - block.timestamp);
        (uint256 principal,,,,,,,) = V.users(alice);
        assertGt(principal, 1_000 ether); // interest folded in
        vm.prank(alice);
        V.withdraw(principal);
        assertEq(V.total_principal(), 0);
    }

    // ── block lock outlives the time lock ──
    function test_BlockLockStillHoldsWhenTimeIsSatisfied() public {
        _deposit(1_000 ether);
        _advance(uint256(LOCK) + 5 days); // plenty of time, but no blocks mined
        vm.prank(alice);
        vm.expectRevert(luv_locker.block_lock_active.selector);
        V.withdraw(1_000 ether);
        // mine the blocks and it opens
        vm.roll(block.number + BLOCKS);
        vm.prank(alice);
        V.withdraw(1_000 ether);
        assertEq(V.total_principal(), 0);
    }
}
