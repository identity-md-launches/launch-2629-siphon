// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract HookFlagsTest is Test {
    function test_constantsAgreeWithV4Core() public pure {
        assertEq(HookFlags.BEFORE_INITIALIZE, Hooks.BEFORE_INITIALIZE_FLAG);
        assertEq(HookFlags.AFTER_INITIALIZE, Hooks.AFTER_INITIALIZE_FLAG);
        assertEq(HookFlags.BEFORE_ADD_LIQUIDITY, Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        assertEq(HookFlags.AFTER_ADD_LIQUIDITY, Hooks.AFTER_ADD_LIQUIDITY_FLAG);
        assertEq(HookFlags.BEFORE_REMOVE_LIQUIDITY, Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        assertEq(HookFlags.AFTER_REMOVE_LIQUIDITY, Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        assertEq(HookFlags.BEFORE_SWAP, Hooks.BEFORE_SWAP_FLAG);
        assertEq(HookFlags.AFTER_SWAP, Hooks.AFTER_SWAP_FLAG);
        assertEq(HookFlags.BEFORE_DONATE, Hooks.BEFORE_DONATE_FLAG);
        assertEq(HookFlags.AFTER_DONATE, Hooks.AFTER_DONATE_FLAG);
        assertEq(HookFlags.BEFORE_SWAP_RETURN_DELTA, Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_SWAP_RETURN_DELTA, Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_ADD_LIQUIDITY_RETURN_DELTA, Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_REMOVE_LIQUIDITY_RETURN_DELTA, Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.ALL, Hooks.ALL_HOOK_MASK);
    }

    function test_flagsOfReadsTheLowFourteenBits() public pure {
        address a = address(uint160(0xABCDEF0000) | HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_SWAP);
        assertEq(HookFlags.flagsOf(a), HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_SWAP);
        assertTrue(HookFlags.matches(a, HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_SWAP));
        assertFalse(HookFlags.matches(a, HookFlags.AFTER_SWAP));
        assertFalse(HookFlags.matches(a, HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_SWAP | HookFlags.BEFORE_SWAP));
    }

    function testFuzz_matchesIgnoresBitsAboveTheMask(uint160 high, uint160 flags) public pure {
        flags &= HookFlags.ALL;
        address a = address((high & ~HookFlags.ALL) | flags);
        assertEq(HookFlags.flagsOf(a), flags);
        assertTrue(HookFlags.matches(a, flags | (high & ~HookFlags.ALL)));
    }
}
