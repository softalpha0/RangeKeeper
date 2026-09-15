// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DemoToken} from "../src/demo/DemoToken.sol";

contract DemoTokenTest is Test {
    DemoToken token;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token = new DemoToken("Demo A", "DMA", 18);
    }

    function test_mint_onlyOwner() public {
        token.mint(alice, 1000e18);
        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.totalSupply(), 1000e18);
    }

    function test_mint_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(DemoToken.NotOwner.selector);
        token.mint(alice, 1000e18);
    }

    function test_transfer_movesRealBalance() public {
        token.mint(alice, 1000e18);
        vm.prank(alice);
        token.transfer(bob, 300e18);
        assertEq(token.balanceOf(alice), 700e18);
        assertEq(token.balanceOf(bob), 300e18);
    }

    function test_transferFrom_respectsAllowance() public {
        token.mint(alice, 1000e18);
        vm.prank(alice);
        token.approve(bob, 300e18);

        vm.prank(bob);
        token.transferFrom(alice, bob, 300e18);
        assertEq(token.balanceOf(bob), 300e18);
        assertEq(token.allowance(alice, bob), 0);

        vm.prank(bob);
        vm.expectRevert(DemoToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 1);
    }

    function test_transferFrom_infiniteApprovalNeverDecrements() public {
        token.mint(alice, 1000e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, bob, 500e18);
        assertEq(token.allowance(alice, bob), type(uint256).max, "infinite approval must not decrement");
    }
}
