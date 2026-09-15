// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DemoTokenFaucet} from "../src/demo/DemoTokenFaucet.sol";
import {DemoToken} from "../src/demo/DemoToken.sol";

contract DemoTokenFaucetTest is Test {
    DemoToken tokenA;
    DemoToken tokenB;
    DemoTokenFaucet faucet;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant CLAIM_A = 1_000e18;
    uint256 constant CLAIM_B = 500e18;

    function setUp() public {
        tokenA = new DemoToken("Demo A", "DMOA", 18);
        tokenB = new DemoToken("Demo B", "DMOB", 18);
        faucet = new DemoTokenFaucet(address(tokenA), address(tokenB), CLAIM_A, CLAIM_B);

        // The deployer (owner of both tokens) funds the faucet the plain
        // way — mint directly to its address, no special faucet-side
        // minting privilege needed.
        tokenA.mint(address(faucet), 10_000e18);
        tokenB.mint(address(faucet), 10_000e18);
    }

    function test_claim_paysBothTokensInOneCall() public {
        vm.prank(alice);
        (uint256 paidA, uint256 paidB) = faucet.claim();

        assertEq(paidA, CLAIM_A);
        assertEq(paidB, CLAIM_B);
        assertEq(tokenA.balanceOf(alice), CLAIM_A);
        assertEq(tokenB.balanceOf(alice), CLAIM_B);
    }

    function test_claim_revertsBeforeCooldownElapses() public {
        vm.prank(alice);
        faucet.claim();

        // Computed before vm.prank — a view call here would consume the
        // prank itself (an argument expression is evaluated, and calls into
        // it, before the outer statement it's used in), leaving the real
        // claim() call after it to run as the test contract, not alice.
        uint256 expectedNextClaimAt = block.timestamp + faucet.COOLDOWN();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DemoTokenFaucet.TooSoon.selector, expectedNextClaimAt));
        faucet.claim();
    }

    function test_claim_succeedsAgainAfterCooldown() public {
        vm.prank(alice);
        faucet.claim();

        vm.warp(block.timestamp + faucet.COOLDOWN());
        vm.prank(alice);
        (uint256 paidA,) = faucet.claim();

        assertEq(paidA, CLAIM_A);
        assertEq(tokenA.balanceOf(alice), 2 * CLAIM_A);
    }

    function test_claim_isPerAddress_notGlobal() public {
        vm.prank(alice);
        faucet.claim();

        // bob is unaffected by alice's cooldown.
        vm.prank(bob);
        (uint256 paidA,) = faucet.claim();
        assertEq(paidA, CLAIM_A);
    }

    function test_claim_paysOutWhateverIsLeft_whenBelowAFullClaim() public {
        // Drain the faucet down to less than one full claim of tokenA.
        vm.prank(alice);
        faucet.claim();
        vm.warp(block.timestamp + faucet.COOLDOWN());

        // 10,000 - 1,000 (alice) = 9,000 left; claim it down further via
        // repeated real claims from distinct addresses until under CLAIM_A.
        for (uint256 i = 0; i < 8; i++) {
            address someone = address(uint160(0x1000 + i));
            vm.prank(someone);
            faucet.claim();
        }
        // 10,000 - 9*1,000 = 1,000 left exactly; one more claim empties tokenA.
        vm.prank(bob);
        faucet.claim();
        assertEq(tokenA.balanceOf(address(faucet)), 0);

        // Next claimer gets a partial (0) tokenA payout, not a revert —
        // tokenB is still available, so the call itself should still succeed.
        address lastOne = address(0x1A57);
        vm.prank(lastOne);
        (uint256 paidA, uint256 paidB) = faucet.claim();
        assertEq(paidA, 0, "tokenA exhausted");
        assertEq(paidB, CLAIM_B, "tokenB still available");
    }

    function test_claim_revertsWhenBothTokensExhausted() public {
        DemoTokenFaucet emptyFaucet = new DemoTokenFaucet(address(tokenA), address(tokenB), CLAIM_A, CLAIM_B);
        vm.prank(alice);
        vm.expectRevert(DemoTokenFaucet.FaucetEmpty.selector);
        emptyFaucet.claim();
    }

    function test_timeUntilNextClaim_zeroBeforeFirstClaim() public view {
        assertEq(faucet.timeUntilNextClaim(alice), 0);
    }

    function test_timeUntilNextClaim_matchesRealCooldown() public {
        vm.prank(alice);
        faucet.claim();
        assertEq(faucet.timeUntilNextClaim(alice), faucet.COOLDOWN());

        vm.warp(block.timestamp + faucet.COOLDOWN() - 10);
        assertEq(faucet.timeUntilNextClaim(alice), 10);

        vm.warp(block.timestamp + 10);
        assertEq(faucet.timeUntilNextClaim(alice), 0);
    }
}
