// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SiphonToken} from "../src/SiphonToken.sol";

contract SiphonTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    address factory = makeAddr("factory");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    SiphonToken token;

    function setUp() public {
        vm.prank(factory);
        token = new SiphonToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "SIPHON");
        assertEq(token.symbol(), "SIPH");
        assertEq(token.decimals(), 18);
    }

    function test_wholeSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(factory), SUPPLY);
    }

    function test_transferMovesExactly() public {
        uint256 amount = SUPPLY / 1000;
        vm.prank(factory);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(factory), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromWithAllowance() public {
        vm.prank(factory);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 60 ether);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 60 ether));
        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.balanceOf(alice), 40 ether);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        vm.prank(factory);
        token.transfer(alice, 100 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_transferBeyondBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_noMintBurnOwnerOrPauseEntryPoints() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "pause()",
            "transferOwnership(address)",
            "setFee(uint256)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(factory);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], factory, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != factory);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(factory);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(factory) + token.balanceOf(to), SUPPLY);
    }
}
