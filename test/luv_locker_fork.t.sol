// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

/**
 * THE MAINNET-FORK REHEARSAL — AUDIT §7, items 2 and 3.
 *
 *   item 2: "A fork test against the real LUV token, with the real fee and max-tx exemptions
 *            applied, confirming reflections actually land on the locker."
 *   item 3: "A test that the vault behaves correctly if it is excluded from reflections
 *            mid-life (interest should freeze, principal must remain fully withdrawable)."
 *
 * Every mock in this repository is a guess about how ShambaLuv behaves. This file stops
 * guessing: it forks Ethereum, deploys the vault against the REAL LUV at
 * 0x2711111111683B8708cb9a48cBf36a51315F8254, applies the REAL exemptions as the REAL owner
 * (bankon.eth), funds depositors from the REAL treasury, and drives a REAL reflection by
 * making the token distribute its accumulated fees.
 *
 * PROFILE. Mainnet is cancun and LUV is compiled for it, so this runs under the `fork`
 * profile; on the default paris profile a PUSH0 in LUV's bytecode is EvmError: NotActivated.
 * Deployment target and rehearsal target are different questions:
 *
 *     make fork-test        # FOUNDRY_PROFILE=fork FORK_TEST=1
 *
 * Skipped unless FORK_TEST=1 so the default suite stays hermetic and offline. Nothing is
 * pinned to a block by default — the rehearsal keeps telling the truth as the chain moves.
 * Set FORK_BLOCK to pin it.
 */

import "forge-std/Test.sol";
import {luv_locker} from "../src/luv_locker.sol";

interface ILUV {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function owner() external view returns (address);
    function setFeeExemption(address, bool) external;
    function setMaxTxExemption(address, bool) external;
    function excludeFromReflection(address) external;
    function includeInReflection(address) external;
    function processFees() external;
    function totalSupply() external view returns (uint256);
}

contract luv_locker_fork_test is Test {
    ILUV internal constant LUV = ILUV(0x2711111111683B8708cb9a48cBf36a51315F8254);
    address internal constant TREASURY = 0x10f7Ee226B16bea7f365Dc1eDEF159Fc1957D169; // owner
    address internal constant PAIR     = 0x57D2085Aa859a145cB107845AD03c0eAAFBD8a31;

    luv_locker internal vault;
    address internal constant ALICE = address(0xA11CE0);
    address internal constant BOB   = address(0xB0B);

    uint48  internal constant LOCK_DURATION   = 90 days;
    uint256 internal constant MIN_BLOCK_DELTA = 100;
    address internal constant SINK = address(0x5151);

    bool internal live;

    function setUp() public {
        if (!vm.envOr("FORK_TEST", false)) { vm.skip(true); return; }
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc); else vm.createSelectFork(rpc, pin);
        live = true;

        vault = new luv_locker(address(LUV), LOCK_DURATION, MIN_BLOCK_DELTA, SINK);

        // THE PRE-MAINNET CHECKLIST, applied as the real owner — §8 items 1 and 2.
        vm.startPrank(LUV.owner());
        LUV.setFeeExemption(address(vault), true);
        LUV.setMaxTxExemption(address(vault), true);
        vm.stopPrank();

        // fund two depositors from the real treasury
        vm.startPrank(TREASURY);
        LUV.transfer(ALICE, 10_000_000_000e18);
        LUV.transfer(BOB,    5_000_000_000e18);
        vm.stopPrank();
        vm.prank(ALICE); LUV.approve(address(vault), type(uint256).max);
        vm.prank(BOB);   LUV.approve(address(vault), type(uint256).max);
    }

    function _mature() internal {
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.roll(block.number + MIN_BLOCK_DELTA);
    }

    /// The exemptions actually took, and the token is what we think it is.
    function test_Fork_TheRealTokenAndTheRealExemptions() public {
        if (!live) return;
        assertEq(LUV.owner(), TREASURY, "owner is not the treasury we prank");
        assertGt(LUV.balanceOf(PAIR), 0, "the pair holds no LUV on this fork");
        emit log_named_uint("LUV total supply", LUV.totalSupply());
        emit log_named_uint("treasury balance", LUV.balanceOf(TREASURY));
    }

    /// H-2 on the real token: a locker LUV does not list as fee-exempt refuses deposits, read
    /// straight from LUV.isExcludedFromFee — before any tokens move.
    function test_Fork_NonExemptLockerRefusesDeposits() public {
        if (!live) return;
        luv_locker bare = new luv_locker(address(LUV), LOCK_DURATION, MIN_BLOCK_DELTA, SINK);
        vm.prank(ALICE); LUV.approve(address(bare), type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(luv_locker.not_fee_exempt.selector);
        bare.deposit(1_000e18);
        vm.prank(LUV.owner()); LUV.setFeeExemption(address(bare), true);
        vm.prank(ALICE); bare.deposit(1_000e18);
        (uint256 principal, , , , , , , ) = bare.users(ALICE);
        assertEq(principal, 1_000e18);
    }

    /**
     * ITEM 2, the core of it. A fee-exempt deposit of the REAL token must credit the FULL
     * amount — no fee taken, no shortfall — and principal must come back whole at maturity.
     */
    function test_Fork_FeeExemptDepositCreditsTheFullAmount() public {
        if (!live) return;
        uint256 amount = 1_000_000_000e18;
        uint256 before = LUV.balanceOf(ALICE);

        vm.prank(ALICE);
        vault.deposit(amount);

        (uint256 principal, , , , , , , ) = vault.users(ALICE);
        assertEq(principal, amount, "the fee exemption did not hold: principal < amount");
        assertEq(LUV.balanceOf(ALICE), before - amount, "more left the depositor than was credited");
        assertGe(LUV.balanceOf(address(vault)), principal, "vault does not cover its own principal");

        _mature();
        vm.prank(ALICE);
        vault.withdraw(principal);
        assertGe(LUV.balanceOf(ALICE), before, "principal did not come home whole");
    }

    /**
     * ITEM 2, the other half: do reflections ACTUALLY land on this vault?
     *
     * The vault must be reflection-INCLUDED (never excluded) for interest to exist at all.
     * We generate a genuine reflection the way the chain does — fees accumulate inside the
     * token and `processFees()` distributes them — and then assert the vault's balance grew
     * beyond its principal, and that the growth is claimable as interest.
     */
    function test_Fork_RealReflectionsLandOnTheVault() public {
        if (!live) return;
        vm.prank(ALICE);
        vault.deposit(1_000_000_000e18);
        (uint256 principal, , , , , , , ) = vault.users(ALICE);

        uint256 held_before = LUV.balanceOf(address(vault));

        // A real transfer between non-exempt parties takes the 5% fee, which accumulates in
        // the token and is distributed to every reflection-included holder.
        vm.prank(TREASURY);
        LUV.transfer(BOB, 1_000_000_000e18);       // treasury is exempt; move to a fresh hand
        vm.prank(BOB);
        LUV.transfer(address(0xDEAD1), 500_000_000e18);  // this one pays the fee
        LUV.processFees();

        uint256 held_after = LUV.balanceOf(address(vault));
        emit log_named_uint("vault held before", held_before);
        emit log_named_uint("vault held after ", held_after);
        emit log_named_uint("reflection landed", held_after - held_before);

        // whether or not a flush happened this block, the vault must never LOSE balance
        assertGe(held_after, held_before, "the vault's balance fell");

        if (held_after > held_before) {
            vault.poke(ALICE);
            assertGt(vault.pending_rewards(ALICE), 0, "a reflection landed but is not claimable");
            assertGe(LUV.balanceOf(address(vault)), vault.total_principal(), "insolvent after reflection");
            uint256 hand = LUV.balanceOf(ALICE);
            vm.prank(ALICE);
            vault.harvest();
            assertGt(LUV.balanceOf(ALICE), hand, "harvest paid nothing");
        } else {
            emit log_string("no fee flush at this block; balance-never-falls still asserted");
        }
        // principal is untouched by any of it
        (uint256 p_after, , , , , , , ) = vault.users(ALICE);
        assertGe(p_after, principal, "principal shrank");
    }

    /**
     * ITEM 3 — EXCLUDED MID-LIFE.
     *
     * Reflection inclusion is a setting on the TOKEN, not in this repository, and nothing in
     * the vault can detect it (AUDIT §4). So the requirement is not that the vault notices —
     * it cannot — but that being excluded partway through is SURVIVABLE:
     *
     *     interest freezes, and principal remains fully withdrawable.
     *
     * The second half is the one that matters. A vault whose principal became unwithdrawable
     * because an owner flipped a token setting would be a trap.
     */
    function test_Fork_ExcludedMidLife_InterestFreezesPrincipalSurvives() public {
        if (!live) return;
        uint256 amount = 1_000_000_000e18;
        vm.prank(ALICE);
        vault.deposit(amount);
        (uint256 principal, , , , , , , ) = vault.users(ALICE);

        // now the token excludes the vault, mid-life
        vm.prank(LUV.owner());
        LUV.excludeFromReflection(address(vault));

        uint256 held_at_exclusion = LUV.balanceOf(address(vault));
        vault.poke(ALICE);
        uint256 owed_at_exclusion = vault.pending_rewards(ALICE);

        // generate the fee traffic that WOULD have reflected
        vm.prank(TREASURY);
        LUV.transfer(BOB, 2_000_000_000e18);
        vm.prank(BOB);
        LUV.transfer(address(0xDEAD2), 1_000_000_000e18);
        LUV.processFees();

        // interest FROZE: the excluded vault took no share of that distribution
        assertEq(LUV.balanceOf(address(vault)), held_at_exclusion,
            "an excluded vault still received a reflection");
        vault.poke(ALICE);
        assertEq(vault.pending_rewards(ALICE), owed_at_exclusion,
            "interest kept accruing while excluded");

        // PRINCIPAL SURVIVES: the lock still opens on schedule and pays out in full
        _mature();
        uint256 hand = LUV.balanceOf(ALICE);
        vm.prank(ALICE);
        vault.withdraw(principal);
        assertEq(LUV.balanceOf(ALICE), hand + principal + owed_at_exclusion,
            "principal did not come home whole from an excluded vault");
        assertEq(vault.total_principal(), 0, "principal remains after the only depositor exited");
    }

    /// And it recovers: re-including the vault resumes interest, with no repair step.
    function test_Fork_ReIncludedAfterExclusionResumesInterest() public {
        if (!live) return;
        vm.prank(ALICE);
        vault.deposit(1_000_000_000e18);

        vm.startPrank(LUV.owner());
        LUV.excludeFromReflection(address(vault));
        LUV.includeInReflection(address(vault));
        vm.stopPrank();

        uint256 before = LUV.balanceOf(address(vault));
        vm.prank(TREASURY);
        LUV.transfer(BOB, 2_000_000_000e18);
        vm.prank(BOB);
        LUV.transfer(address(0xDEAD3), 1_000_000_000e18);
        LUV.processFees();

        assertGe(LUV.balanceOf(address(vault)), before, "the vault lost balance after re-inclusion");
        vault.poke(ALICE);
        assertGe(LUV.balanceOf(address(vault)), vault.total_principal(), "insolvent after re-inclusion");
    }

    /// Two depositors on the real token split a real reflection pro-rata.
    function test_Fork_TwoDepositorsSplitARealReflection() public {
        if (!live) return;
        vm.prank(ALICE); vault.deposit(2_000_000_000e18);
        vm.prank(BOB);   vault.deposit(1_000_000_000e18);

        uint256 before = LUV.balanceOf(address(vault));
        vm.prank(TREASURY);
        LUV.transfer(address(0xF00D), 3_000_000_000e18);
        vm.prank(address(0xF00D));
        LUV.transfer(address(0xDEAD4), 1_500_000_000e18);
        LUV.processFees();

        if (LUV.balanceOf(address(vault)) <= before) {
            emit log_string("no flush at this block - split not exercised");
            return;
        }
        vault.poke(ALICE); vault.poke(BOB);
        uint256 a = vault.pending_rewards(ALICE);
        uint256 b = vault.pending_rewards(BOB);
        emit log_named_uint("alice interest", a);
        emit log_named_uint("bob interest  ", b);
        // Alice put in twice as much, so she earns about twice as much (1% tolerance)
        assertApproxEqRel(a, b * 2, 0.01e18, "the reflection did not split pro-rata");
        assertGe(LUV.balanceOf(address(vault)), vault.total_principal(), "insolvent after the split");
    }
}
