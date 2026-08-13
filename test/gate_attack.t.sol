// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

/**
 * GATE ATTACK — an adversarial pass at the LUV vault's TIME element and its yield.
 *
 * The sibling file in liq-locker attacks the ownerless ERC-20 timelock. This one attacks the
 * reflection vault, which is the harder target: it holds a token that REBASES UPWARD DURING A
 * TRANSFER, and that is precisely what audit finding C-1 turned into a theft in the live
 * `LUVLocker 0xe07ACAde…B898`. Every test is written as an attacker; a PASS means the attempt
 * failed.
 *
 *   1. the rolling lock — the time gate, its boundary, and whether a deposit can shorten it
 *   2. the block lock   — the second gate, and the same boundary question
 *   3. C-1              — dust deposited into a reflection must not absorb it as principal
 *   4. authority        — extend_lock is self-only (audit A1: no owner hostage path)
 *   5. custody          — no owner, no rescue, and LUV can never be swept out
 */

import "forge-std/Test.sol";
import {luv_locker} from "../src/luv_locker.sol";
import {mock_luv, mock_foreign} from "./mocks.sol";

/// The vault's balance rises by MORE than the transfer, inside the transfer — the C-1 shape.
contract reflecting_luv {
    string public name = "SHAMBA LUV";
    string public symbol = "LUV";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public armedHolder;
    uint256 public armedAmount;

    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function reflect(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function arm(address h, uint256 a) external { armedHolder = h; armedAmount = a; }

    function _flush() internal {
        if (armedAmount != 0) {
            balanceOf[armedHolder] += armedAmount;
            totalSupply += armedAmount;
            armedAmount = 0; armedHolder = address(0);
        }
    }
    function transfer(address to, uint256 v) external returns (bool) {
        _flush();
        balanceOf[msg.sender] -= v; balanceOf[to] += v; return true;
    }
    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        _flush();
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= v;
        balanceOf[f] -= v; balanceOf[t] += v; return true;
    }
}

contract luv_gate_attack_test is Test {
    luv_locker internal vault;
    mock_luv internal luv;

    address internal constant SINK    = address(0x5151);
    address internal constant ALICE   = address(0xA11CE0);
    address internal constant BOB     = address(0xB0B);
    address internal constant MALLORY = address(0xBAD);

    uint48  internal constant LOCK_DURATION  = 90 days;
    uint256 internal constant MIN_BLOCK_DELTA = 100;
    uint256 internal constant AMT = 1_000_000e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(20_000_000);
        luv = new mock_luv();
        vault = new luv_locker(address(luv), LOCK_DURATION, MIN_BLOCK_DELTA, SINK);
        for (uint256 i = 0; i < 3; i++) {
            address who = i == 0 ? ALICE : i == 1 ? BOB : MALLORY;
            luv.mint(who, 10 * AMT);
            vm.prank(who);
            luv.approve(address(vault), type(uint256).max);
        }
    }

    function _deposit(address who, uint256 amt) internal {
        vm.prank(who);
        vault.deposit(amt);
    }

    /// past both gates, without touching anyone's balances
    function _matureFully() internal {
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.roll(block.number + MIN_BLOCK_DELTA);
    }

    // ─────────────────────────────────────────────── 1. the rolling time lock
    function test_attack_WithdrawOneSecondEarlyFails() public {
        _deposit(ALICE, AMT);
        vm.roll(block.number + MIN_BLOCK_DELTA);          // clear the block gate only
        vm.warp(block.timestamp + LOCK_DURATION - 1);
        vm.prank(ALICE);
        vm.expectRevert(luv_locker.time_lock_active.selector);
        vault.withdraw(AMT);
    }

    function test_attack_WithdrawExactlyAtMaturitySucceeds() public {
        _deposit(ALICE, AMT);
        _matureFully();
        vm.prank(ALICE);
        vault.withdraw(AMT);
        assertEq(luv.balanceOf(ALICE), 10 * AMT, "principal did not come home whole");
    }

    /// A proposer's few seconds of drift must not buy an early exit.
    function test_attack_ProposerDriftCannotOpenTheLock() public {
        _deposit(ALICE, AMT);
        vm.roll(block.number + MIN_BLOCK_DELTA);
        uint256 mature = block.timestamp + LOCK_DURATION;
        for (uint256 d = 1; d <= 900; d += 149) {
            vm.warp(mature - d);
            vm.prank(ALICE);
            vm.expectRevert(luv_locker.time_lock_active.selector);
            vault.withdraw(AMT);
        }
    }

    /// A second deposit may only ever push maturity OUT, never pull it in.
    function test_attack_SecondDepositCannotShortenTheLock() public {
        _deposit(ALICE, AMT);
        vm.prank(ALICE);
        vault.extend_lock(uint48(block.timestamp + 3650 days));   // a very long self-lock
        _deposit(ALICE, 1);                                       // then try to reset it
        _matureFully();
        vm.prank(ALICE);
        vm.expectRevert(luv_locker.time_lock_active.selector);
        vault.withdraw(AMT);                                      // still held by the long lock
    }

    /// DOCUMENTED, NOT A BUG: topping up re-locks the WHOLE balance for a fresh term.
    /// Only the depositor can do it to themselves — there is no deposit_for(other) — so it
    /// is a footgun, not a griefing vector. Pinned so it can never become one silently.
    function test_attack_TopUpRelocksTheWholeBalance() public {
        _deposit(ALICE, AMT);
        vm.warp(block.timestamp + LOCK_DURATION - 1 days);
        _deposit(ALICE, 1);                       // a dust top-up, one day before maturity
        vm.warp(block.timestamp + 1 days + 1);    // past the ORIGINAL maturity
        vm.roll(block.number + MIN_BLOCK_DELTA);
        vm.prank(ALICE);
        vm.expectRevert(luv_locker.time_lock_active.selector);
        vault.withdraw(AMT);
    }

    /// Nobody can deposit on someone else's behalf, so nobody can re-lock their balance.
    function test_attack_CannotRelockAnotherUser() public {
        _deposit(ALICE, AMT);
        _deposit(MALLORY, AMT);                   // Mallory depositing must not touch Alice
        _matureFully();
        vm.prank(ALICE);
        vault.withdraw(AMT);                      // Alice is free on her own schedule
    }

    // ─────────────────────────────────────────────── 2. the block lock
    function test_attack_BlockLockHoldsWhenTimeHasPassed() public {
        _deposit(ALICE, AMT);
        vm.warp(block.timestamp + LOCK_DURATION * 10);   // time long gone
        vm.roll(block.number + MIN_BLOCK_DELTA - 1);     // one block short
        vm.prank(ALICE);
        vm.expectRevert(luv_locker.block_lock_active.selector);
        vault.withdraw(AMT);
    }

    function test_attack_NoAmountOfTimeSkipsABlock() public {
        _deposit(ALICE, AMT);
        vm.warp(block.timestamp + 200 * 365 days);       // two centuries
        vm.prank(ALICE);
        vm.expectRevert(luv_locker.block_lock_active.selector);
        vault.withdraw(AMT);
    }

    // ─────────────────────────────────────────────── 3. C-1, the live vault's theft
    /**
     * THE ATTACK THAT WORKS ON THE LIVE LUVLocker 0xe07ACAde…B898.
     * Mallory watches for a pending fee flush, deposits 1 wei, and the vault's balance
     * rises by the whole reflection during her transferFrom. If the vault credits the
     * measured delta as principal, she has just bought the other depositors' yield for
     * 1 wei. Here the credit is capped at what was asked, and the surplus goes to the
     * index pro-rata, so she gets a reflection share proportional to 1 wei — i.e. none.
     */
    function test_attack_C1_DustDepositCannotAbsorbAReflection() public {
        reflecting_luv rl = new reflecting_luv();
        luv_locker v = new luv_locker(address(rl), LOCK_DURATION, MIN_BLOCK_DELTA, SINK);
        rl.mint(ALICE, AMT); rl.mint(MALLORY, AMT);
        vm.prank(ALICE);   rl.approve(address(v), type(uint256).max);
        vm.prank(MALLORY); rl.approve(address(v), type(uint256).max);

        vm.prank(ALICE); v.deposit(AMT);                   // the honest depositor, first

        uint256 REFLECTION = 500_000e18;
        rl.arm(address(v), REFLECTION);                    // a flush is pending
        vm.prank(MALLORY); v.deposit(1);                   // 1 wei, timed into the flush

        // Mallory's principal is 1 wei, not 1 wei + the reflection
        (uint256 mallory_principal, , , , , , , ) = v.users(MALLORY);
        assertEq(mallory_principal, 1, "C-1: dust deposit absorbed the reflection as principal");

        // and the reflection belongs to the principal that existed when it landed
        uint256 alice_pending   = v.pending_rewards(ALICE);
        uint256 mallory_pending = v.pending_rewards(MALLORY);
        assertGe(alice_pending, (REFLECTION * 999) / 1000, "the reflection did not reach Alice");
        assertLe(mallory_pending, REFLECTION / 1_000_000, "Mallory retro-earned the reflection");
    }

    /// The same attack from the other side: the late depositor must not earn what was
    /// distributed before they arrived.
    function test_attack_LateDepositorCannotRetroEarn() public {
        _deposit(ALICE, AMT);
        luv.reflect(address(vault), 100_000e18);           // yield for Alice alone
        _deposit(MALLORY, AMT);                            // Mallory arrives after
        assertEq(vault.pending_rewards(MALLORY), 0, "the newcomer retro-earned");
        assertGe(vault.pending_rewards(ALICE), (100_000e18 * 999) / 1000, "Alice lost her yield");
    }

    // ─────────────────────────────────────────────── 4. authority (audit A1)
    function test_attack_NobodyCanExtendAnotherUsersLock() public {
        _deposit(ALICE, AMT);
        vm.prank(MALLORY);
        vm.expectRevert(luv_locker.insufficient_principal.selector);
        vault.extend_lock(uint48(block.timestamp + 3650 days));   // no third-party path
        _matureFully();
        vm.prank(ALICE);
        vault.withdraw(AMT);                                       // Alice still gets out
    }

    function test_attack_ExtendLockCannotShorten() public {
        _deposit(ALICE, AMT);
        vm.prank(ALICE);
        vm.expectRevert(luv_locker.not_shortenable.selector);
        vault.extend_lock(uint48(block.timestamp + 1));            // earlier than maturity
    }

    function test_attack_ExtendLockCannotExceedTheHorizon() public {
        _deposit(ALICE, AMT);
        vm.prank(ALICE);
        vm.expectRevert(luv_locker.duration_too_long.selector);
        vault.extend_lock(type(uint48).max);
    }

    function test_attack_CannotWithdrawMoreThanPrincipal() public {
        _deposit(ALICE, AMT);
        _matureFully();
        vm.prank(ALICE);
        vm.expectRevert(luv_locker.insufficient_principal.selector);
        vault.withdraw(AMT + 1);
    }

    function test_attack_CannotWithdrawSomeoneElsesPrincipal() public {
        _deposit(ALICE, AMT);
        _matureFully();
        vm.prank(MALLORY);
        vm.expectRevert(luv_locker.insufficient_principal.selector);
        vault.withdraw(AMT);
    }

    // ─────────────────────────────────────────────── 5. custody
    function test_attack_LuvCanNeverBeSweptOut() public {
        _deposit(ALICE, AMT);
        vm.prank(MALLORY);
        vm.expectRevert(luv_locker.cannot_sweep_luv.selector);
        vault.sweep_foreign(address(luv));
        _matureFully();
        vm.prank(ALICE);
        vault.withdraw(AMT);
        assertEq(luv.balanceOf(ALICE), 10 * AMT, "principal did not survive the sweep attempt");
    }

    /// Interest is never locked, even while principal is — and it is the depositor's alone.
    function test_attack_HarvestDoesNotUnlockPrincipal() public {
        _deposit(ALICE, AMT);
        luv.reflect(address(vault), 50_000e18);
        vm.prank(ALICE);
        vault.harvest();                                   // interest out, mid-lock
        vm.prank(ALICE);
        vm.expectRevert(luv_locker.time_lock_active.selector);
        vault.withdraw(AMT);                               // principal stays put
    }

}
