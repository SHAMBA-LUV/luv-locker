// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TimeBase} from "./time_base.sol";
import {luv_locker} from "../src/luv_locker.sol";

/**
 * @notice A faithful-er LUV mock: the real ShambaLuv runs `_processFees()` at the TOP of
 *         `_transfer`, which distributes a pending reflection to every reflection-included
 *         holder — including this vault — BEFORE the transfer completes. So the vault's
 *         balance can rise by MORE than the amount transferred in, inside a single
 *         `transferFrom`. The stock `mock_luv` only reflects via a separate `reflect()`
 *         call and therefore cannot exercise this path at all.
 *
 *         Model: `arm(holder, amt)` queues a reflection that fires on the NEXT transfer,
 *         crediting `amt` to `holder`. This reproduces "accumulatedFees >= payoutThreshold,
 *         next transfer flushes it" without needing the full RFI machinery.
 */
contract mock_luv_reflect_on_transfer {
    string public name = "SHAMBA LUV";
    string public symbol = "LUV";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public armedHolder;
    uint256 public armedAmount;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; }
    function reflect(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    /// @notice Queue a reflection to land on `holder` at the top of the next transfer.
    function arm(address holder, uint256 amount) external { armedHolder = holder; armedAmount = amount; }

    function _flush() internal {
        if (armedAmount != 0) {
            balanceOf[armedHolder] += armedAmount;
            totalSupply += armedAmount;
            armedAmount = 0;
            armedHolder = address(0);
        }
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _flush(); // reflection distributes BEFORE the move, exactly like _processFees at the top of _transfer
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _flush();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract luv_locker_reflect_on_transfer_test is TimeBase {
    luv_locker internal V;
    mock_luv_reflect_on_transfer internal luv;

    address internal alice = address(0xA11CE); // honest depositor, holds all principal
    address internal mallory = address(0xBAD);  // attacker, deposits dust to capture the reflection
    address internal sink = address(0x5142);

    uint48 internal constant LOCK = 365 days;
    uint256 internal constant BLOCKS = 10;

    function setUp() public {
        _startClock(1_800_000_000);
        vm.roll(1_000_000);
        luv = new mock_luv_reflect_on_transfer();
        V = new luv_locker(address(luv), LOCK, BLOCKS, sink);
        luv.mint(alice, 1_000_000 ether);
        luv.mint(mallory, 1_000_000 ether);
        vm.prank(alice);
        luv.approve(address(V), type(uint256).max);
        vm.prank(mallory);
        luv.approve(address(V), type(uint256).max);
    }

    /**
     * The reflection that fires during mallory's tiny deposit belongs to alice, who held
     * 100% of the principal when it was earned. It must become alice's claimable interest,
     * NOT mallory's principal. Before the fix, mallory's measured delta = 1 wei + the whole
     * reflection, and total_principal absorbs it, leaving alice zero interest.
     */
    function test_ReflectionDuringDepositGoesToTheIndexNotTheDepositor() public {
        // alice is the only staker
        vm.prank(alice);
        V.deposit(1_000 ether);
        assertEq(V.total_principal(), 1_000 ether);

        // a 100-LUV reflection is armed (models fees over threshold, flushed on next transfer)
        luv.arm(address(V), 100 ether);

        // mallory front-runs with a 1-wei deposit; the reflection flushes during his transferFrom
        vm.prank(mallory);
        V.deposit(1);

        // the reflection must be alice's interest, not mallory's principal
        uint256 aliceInterest = V.pending_rewards(alice);
        (uint256 malloryPrincipal,,,,,,,) = V.users(mallory);

        assertApproxEqAbs(aliceInterest, 100 ether, 1e15, "alice should earn the ~100 LUV reflection");
        assertApproxEqAbs(malloryPrincipal, 1, 2, "mallory principal must be ~1 wei, not the reflection");
        // and the vault must remain solvent: balance covers principal + claimable interest
        assertGe(luv.balanceOf(address(V)), V.total_principal());
    }

    /**
     * M-3: a reflection that flushes during an OUTGOING transfer (here, alice's withdraw)
     * must not be orphaned by the trailing sync. It should become claimable interest for
     * the depositors who remain (bob), not vanish into the vault balance forever.
     */
    function test_ReflectionDuringWithdrawIsNotOrphaned() public {
        vm.prank(alice);
        V.deposit(1_000 ether);
        vm.prank(mallory);
        V.deposit(1_000 ether); // bob-role: a second depositor who stays in

        // mature alice's lock
        _advance(LOCK);
        vm.roll(block.number + BLOCKS);

        // arm a reflection to flush during alice's outgoing principal transfer
        luv.arm(address(V), 60 ether);
        vm.prank(alice);
        V.withdraw(1_000 ether);

        // the 60-LUV reflection must be claimable by the remaining depositor, not stuck
        uint256 remaining = V.pending_rewards(mallory);
        assertApproxEqAbs(remaining, 60 ether, 1e15, "reflection during withdraw was orphaned");
        assertGe(luv.balanceOf(address(V)), V.total_principal());
    }
}
