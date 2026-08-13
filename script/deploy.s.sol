// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Script.sol";
import {luv_locker} from "../src/luv_locker.sol";

/**
 * @title  Deploy
 * @notice Deploys the reflection lock.
 *
 * @dev    EVERY ARGUMENT IS IRREVERSIBLE. LOCK_DURATION in particular: the live vault
 *         let an owner change it for future deposits, and this one does not. A different
 *         horizon means a different deployment.
 *
 *         AFTER DEPLOYING, TWO SETTINGS ON THE TOKEN DECIDE WHETHER THIS WORKS AT ALL,
 *         and neither is in this repository:
 *
 *           LUV.setFeeExemption(locker, true)    — deposits and withdrawals are contract
 *           LUV.setMaxTxExemption(locker, true)    transfers and must not pay the buy/sell
 *                                                  fee or hit the max-tx cap.
 *
 *           The locker must stay reflection-INCLUDED. Never call excludeFromReflection on
 *           it. The reflections landing on this contract's balance ARE the interest; if
 *           the token stops sending them, interest silently stops accruing and nothing in
 *           the contract can detect that. Verify it on-chain after deployment, and again
 *           after any change to the token.
 */
contract Deploy is Script {
    function run() external {
        address luv = vm.envAddress("LUV_TOKEN");
        uint48 lock_duration = uint48(vm.envUint("LOCK_DURATION"));
        uint256 min_block_delta = vm.envUint("MIN_BLOCK_DELTA");
        address surplus_sink = vm.envAddress("SURPLUS_SINK");

        vm.startBroadcast();
        luv_locker locker = new luv_locker(luv, lock_duration, min_block_delta, surplus_sink);
        vm.stopBroadcast();

        console2.log("luv_locker      :", address(locker));
        console2.log("LUV             :", luv);
        console2.log("lock duration   :", lock_duration);
        console2.log("min block delta :", min_block_delta);
        console2.log("");
        console2.log("NOW DO THIS, or the vault earns nothing:");
        console2.log("  1. LUV.setFeeExemption(locker, true)");
        console2.log("  2. LUV.setMaxTxExemption(locker, true)");
        console2.log("  3. confirm the locker is NOT excluded from reflections");
    }
}
