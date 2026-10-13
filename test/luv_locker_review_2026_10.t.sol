// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {luv_locker} from "../src/luv_locker.sol";

/// @dev A LUV stand-in that can (a) flush a reflection onto a holder at the top of the next
///      transfer, as LUV's _processFees does, (b) charge a fee, and (c) report fee exemption
///      the way LUV does, through isExcludedFromFee.
contract flush_luv {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isExcludedFromFee;
    uint256 public fee_bps;
    address armed_holder;
    uint256 armed_amount;

    function mint(address t, uint256 a) external { balanceOf[t] += a; }
    function arm(address holder, uint256 a) external { armed_holder = holder; armed_amount = a; }
    function set_fee(uint256 b) external { fee_bps = b; }
    function set_exempt(address a, bool v) external { isExcludedFromFee[a] = v; }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function _move(address f, address t, uint256 a) internal {
        if (armed_amount != 0) { balanceOf[armed_holder] += armed_amount; armed_amount = 0; }
        uint256 fee = (isExcludedFromFee[f] || isExcludedFromFee[t]) ? 0 : (a * fee_bps) / 10_000;
        balanceOf[f] -= a;
        balanceOf[t] += a - fee;
    }

    function transfer(address t, uint256 a) external returns (bool) { _move(msg.sender, t, a); return true; }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        _move(f, t, a);
        return true;
    }
}

/// The three findings of the 2026-10-12 review, each as the attack that demonstrated it.
contract luv_locker_review_2026_10 is Test {
    flush_luv L;
    luv_locker V;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address mal = address(0xBAD);

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(100);
        L = new flush_luv();
        V = new luv_locker(address(L), 30 days, 10, address(0x5151));
        L.set_exempt(address(V), true); // production precondition
        address[3] memory u = [alice, bob, mal];
        for (uint256 i; i < 3; i++) {
            L.mint(u[i], 1e33);
            vm.prank(u[i]);
            L.approve(address(V), type(uint256).max);
        }
    }

    /// H-1. Was: 1 wei deposit + 1e30 donation + harvest made every later deposit above ~116 LUV
    /// revert forever. Now the index is inflated but nothing overflows and deposits still work.
    function test_H1_index_inflation_no_longer_bricks_deposits() public {
        vm.prank(mal);
        V.deposit(1);
        vm.prank(mal);
        L.transfer(address(V), 1e30);
        vm.prank(mal);
        V.harvest();
        assertGt(V.acc_reward_per_principal(), 1e56, "the index really is inflated");

        vm.prank(bob);
        V.deposit(1_000_000_000e18); // a billion LUV: the size that used to revert
        (uint256 p,,,,,,,) = V.users(bob);
        assertEq(p, 1_000_000_000e18);
        assertEq(V.pending_rewards(bob), 0, "a new depositor owes and is owed nothing");

        // the vault still pays correctly afterwards
        L.mint(address(V), 1_000e18); // a reflection
        vm.roll(block.number + 20);
        vm.prank(bob);
        uint256 got = V.harvest();
        assertApproxEqAbs(got, 1_000e18, 1e6, "bob holds ~all principal, earns ~all of it");
        vm.warp(block.timestamp + 31 days);
        vm.prank(bob);
        V.withdraw(1_000_000_000e18);
        assertEq(L.balanceOf(bob), 1e33 - 1_000_000_000e18 + got + 1_000_000_000e18);
    }

    function testFuzz_H1_mul_acc_matches_naive_where_naive_fits(uint256 a, uint256 b) public {
        a = bound(a, 0, type(uint128).max);
        b = bound(b, 0, type(uint128).max);
        luv_locker_harness h = new luv_locker_harness(address(L));
        assertEq(h.mul_acc(a, b), (a * b) / 1e27);
    }

    function test_H1_mul_acc_exact_beyond_naive() public {
        luv_locker_harness h = new luv_locker_harness(address(L));
        // 1.11e35 (LUV supply) x 1e57 (the inflated index) / 1e27 = 1.11e65, exact
        assertEq(h.mul_acc(111_111_111_111_111_111_111_111_111_111_111_111, 1e57), 111_111_111_111_111_111_111_111_111_111_111_111 * 1e30);
        // odd digits: (2^200 + 12345) * (10^27 * 7 + 3) / 10^27, checked against Python's int
        assertEq(
            h.mul_acc((1 << 200) + 12345, 7e27 + 3),
            11248566309812931928793734651208952350432391783105436124219534
        );
    }

    /// H-2. Was: with the 5% fee on, 1000 deposit + 40 reflection arrived as 990, the cap did
    /// nothing, and the attacker was credited the incumbent's 40. Now a fee-paying deposit reverts.
    function test_H2_fee_paying_deposit_is_refused() public {
        vm.prank(alice);
        V.deposit(1000e18);
        L.set_exempt(address(V), false);
        L.set_fee(500);
        L.arm(address(V), 40e18);
        vm.prank(mal);
        vm.expectRevert(luv_locker.not_fee_exempt.selector);
        V.deposit(1000e18);
    }

    /// H-2 with the exemption in place: the reflection that flushes during the attacker's own
    /// deposit goes to the incumbent; the attacker is credited exactly what they sent.
    function test_H2_exempt_flush_goes_to_incumbent() public {
        vm.prank(alice);
        V.deposit(1000e18);
        L.arm(address(V), 40e18);
        vm.prank(mal);
        V.deposit(1000e18);
        (uint256 p,,,,,,,) = V.users(mal);
        assertEq(p, 1000e18);
        assertEq(V.pending_rewards(alice), 40e18);
        assertEq(V.pending_rewards(mal), 0);
    }

    /// M-4. Was: Alice (1000) got 10 of a 100 reflection that flushed during Bob's 9000 deposit,
    /// Bob got 0, and 90 LUV stayed in the vault forever. Now Alice gets all 100 and nothing strands.
    function test_M4_deposit_time_reflection_is_not_orphaned() public {
        vm.prank(alice);
        V.deposit(1000e18);
        L.arm(address(V), 100e18);
        vm.prank(bob);
        V.deposit(9000e18);
        assertEq(V.pending_rewards(alice), 100e18);
        assertEq(V.pending_rewards(bob), 0);

        vm.warp(1_000_000 + 31 days);
        vm.roll(200);
        vm.prank(alice);
        V.withdraw(1000e18);
        vm.prank(alice);
        V.harvest();
        vm.prank(bob);
        V.withdraw(9000e18);
        assertEq(V.total_principal(), 0);
        assertEq(L.balanceOf(address(V)), 0, "nothing stranded");
    }

    /// M-4, top-up: a depositor adding to an existing position keeps their share of a reflection
    /// that flushes during their own top-up.
    function test_M4_top_up_keeps_own_share_of_flush() public {
        vm.prank(alice);
        V.deposit(1000e18);
        vm.prank(bob);
        V.deposit(3000e18);
        L.arm(address(V), 400e18);
        vm.prank(alice);
        V.deposit(500e18);
        assertEq(V.pending_rewards(alice), 100e18, "1000 of 4000 earned a quarter");
        assertEq(V.pending_rewards(bob), 300e18);
    }
}

contract luv_locker_harness is luv_locker {
    constructor(address luv) luv_locker(luv, 1 days, 1, address(1)) {}
    function mul_acc(uint256 a, uint256 b) external pure returns (uint256) { return _mul_acc(a, b); }
}
