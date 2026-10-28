// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DeploySiphon} from "../script/DeploySiphon.s.sol";
import {SiphonHook} from "../src/SiphonHook.sol";
import {SiphonToken} from "../src/SiphonToken.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract DeploySiphonTest is Test {
    address owner = makeAddr("owner");

    function test_mineSaltAndDeployLandOnTheFlags() public {
        IPoolManager manager = IPoolManager(address(new PoolManager(address(this))));
        DeploySiphon script = new DeploySiphon();
        (bytes32 salt, address predicted) = script.mineSalt(address(script), manager, owner);
        SiphonHook hook = script.deployHook(manager, owner, salt);
        assertEq(address(hook), predicted);
        assertTrue(HookFlags.matches(address(hook), script.HOOK_FLAGS()));
        assertEq(hook.owner(), owner);
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_deployTokenMintsToTheCaller() public {
        DeploySiphon script = new DeploySiphon();
        SiphonToken token = script.deployToken();
        assertEq(token.balanceOf(address(script)), 10 ** 27);
    }
}
