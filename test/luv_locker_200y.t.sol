// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TimeBase} from "./time_base.sol";
import {luv_locker} from "../src/luv_locker.sol";
import {luv_locker_200y} from "../src/luv_locker_200y.sol";
import {mock_luv} from "./mocks.sol";

/**
 * luv_locker_200y: the original contract with MAX_LOCK_DURATION = 73,050 days (200 years)
 * in place of 3,650. Only the horizon changed, so this suite tests only the horizon. Each
 * test that matters runs against both contracts: the decade lock refuses what the
 * two-century lock accepts. The rest of the behaviour is covered by running the whole suite
 * against luv_locker_200y: `make test-200y`.
 */
contract luv_locker_200y_test is TimeBase {
    luv_locker internal V10;
    luv_locker_200y internal V200;
    mock_luv internal luv;

    address internal alice = address(0xA11CE);
    address internal sink = address(0x5142);

    uint48 internal constant LOCK = 365 days;
    uint256 internal constant BLOCKS = 10;
    uint256 internal constant TWO_CENTURIES = 73_050 days;

    function setUp() public {
        _startClock(1_800_000_000);
        vm.roll(1_000_000);
        luv = new mock_luv();
        V10 = new luv_locker(address(luv), LOCK, BLOCKS, sink);
        V200 = new luv_locker_200y(address(luv), LOCK, BLOCKS, sink);
        luv.mint(alice, 10_000_000 ether);
        vm.startPrank(alice);
        luv.approve(address(V10), type(uint256).max);
        luv.approve(address(V200), type(uint256).max);
        vm.stopPrank();
    }

    function test_200y_HorizonIsTwoCenturies() public view {
        assertEq(V200.MAX_LOCK_DURATION(), TWO_CENTURIES);
        assertEq(V200.MAX_LOCK_DURATION(), 200 * 36_525 days / 100);
        assertEq(V10.MAX_LOCK_DURATION(), 3650 days, "the original keeps its decade");
    }

    function test_200y_ConstructorAcceptsTwoCenturiesRejectsOneSecondMore() public {
        luv_locker_200y v = new luv_locker_200y(address(luv), uint48(TWO_CENTURIES), BLOCKS, sink);
        assertEq(v.LOCK_DURATION(), TWO_CENTURIES);
        vm.expectRevert(luv_locker_200y.duration_too_long.selector);
        new luv_locker_200y(address(luv), uint48(TWO_CENTURIES + 1), BLOCKS, sink);
        // the original refuses the same constructor argument
        vm.expectRevert(luv_locker.duration_too_long.selector);
        new luv_locker(address(luv), uint48(TWO_CENTURIES), BLOCKS, sink);
    }

    /// The difference, side by side: an eleven-year extension is refused by the decade lock
    /// and accepted by the two-century lock.
    function test_200y_ExtendPastADecadeOnlyOnTheTwoCenturyLock() public {
        vm.startPrank(alice);
        V10.deposit(1_000 ether);
        V200.deposit(1_000 ether);
        uint48 eleven_years = uint48(block.timestamp + 11 * 365 days);
        vm.expectRevert(luv_locker.duration_too_long.selector);
        V10.extend_lock(eleven_years);
        V200.extend_lock(eleven_years);
        vm.stopPrank();
        (, , , , , uint48 unlock_at, , ) = V200.users(alice);
        assertEq(unlock_at, eleven_years);
    }

    function test_200y_ExtendRejectsBeyondTwoCenturies() public {
        vm.prank(alice);
        V200.deposit(1_000 ether);
        vm.prank(alice);
        vm.expectRevert(luv_locker_200y.duration_too_long.selector);
        V200.extend_lock(uint48(block.timestamp + TWO_CENTURIES + 1));
    }

    /// A full two-century lock: reflections arrive and are harvested as interest all the way
    /// through, the principal stays locked to the second, and opens at the horizon.
    function test_200y_FullHorizonLockHarvestAndWithdraw() public {
        vm.prank(alice);
        V200.deposit(2_000 ether);
        uint48 far = uint48(block.timestamp + TWO_CENTURIES);
        vm.prank(alice);
        V200.extend_lock(far);
        vm.roll(block.number + BLOCKS);

        uint256 harvested;
        for (uint256 i; i < 8; i++) {
            _advance(TWO_CENTURIES / 8 - 1);
            luv.reflect(address(V200), 10 ether);
            vm.prank(alice);
            harvested += V200.harvest();
        }
        assertApproxEqAbs(harvested, 80 ether, 1e9, "every reflection reaches the depositor as interest");

        // one second before two centuries: still locked
        _advance(T > far - 1 ? 0 : far - 1 - T);
        vm.prank(alice);
        vm.expectRevert(luv_locker_200y.time_lock_active.selector);
        V200.withdraw(2_000 ether);

        _advance(1);
        assertEq(block.timestamp, far);
        uint256 before = luv.balanceOf(alice);
        vm.prank(alice);
        V200.withdraw(2_000 ether);
        assertEq(luv.balanceOf(alice) - before, 2_000 ether);
        assertEq(V200.total_principal(), 0);
    }
}
