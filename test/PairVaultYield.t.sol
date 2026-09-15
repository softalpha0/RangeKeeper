// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PairVault} from "../src/PairVault.sol";
import {MockERC20, MockPyth} from "./PairVault.t.sol";
import {AaveV3YieldAdapter} from "../src/adapters/AaveV3YieldAdapter.sol";
import {MockAavePool} from "./AaveV3YieldAdapter.t.sol";

/// @notice Exercises PairVault's "spare pocket" wiring against a real
///         AaveV3YieldAdapter + MockAavePool — the same real share-accounting
///         code AaveV3YieldAdapter.t.sol tests, now driven through PairVault's
///         own sweepIdleToYield/sweepYieldToIdle/navWad rather than called
///         directly. Every existing PairVault test (deposit/withdraw/band)
///         keeps using yieldSource = address(0) and is completely unaffected
///         by this — that's the point of keeping the feature purely additive.
contract PairVaultYieldTest is Test {
    PairVault vault;
    MockERC20 usdc;
    MockERC20 weth;
    MockPyth pyth;
    MockAavePool pool;
    AaveV3YieldAdapter adapter;

    bytes32 constant USDC_FEED = bytes32(uint256(1));
    bytes32 constant WETH_FEED = bytes32(uint256(2));
    address alice = address(0xA11CE);
    address treasury = address(0x7EA5);

    function setUp() public {
        usdc = new MockERC20("USDC", 6);
        weth = new MockERC20("WETH", 18);
        pyth = new MockPyth();
        pyth.setPrice(USDC_FEED, 1e8, -8); // $1.00
        pyth.setPrice(WETH_FEED, 3000e8, -8); // $3,000.00

        pool = new MockAavePool();
        adapter = new AaveV3YieldAdapter(address(pool), address(pool));
        pool.registerAsset(address(usdc));
        pool.registerAsset(address(weth));

        // address(0) for poolManager, like test/PairVault.t.sol — this suite
        // never touches openBand/closeBand.
        vault = new PairVault(
            address(usdc), address(weth), 6, 18, USDC_FEED, WETH_FEED, address(pyth), address(0), 1, address(this), treasury, address(adapter)
        );

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        vault.deposit(address(usdc), 100_000e6); // $100k idle
    }

    function test_sweepIdleToYield_movesSweepBpsIntoTheYieldSource_navUnchanged() public {
        uint256 navBefore = vault.navWad();

        vault.sweepIdleToYield();

        // SWEEP_BPS = 8000 (80%) of idle tvlA.
        assertEq(vault.tvlA(), 20_000e6, "20% stays idle");
        assertEq(adapter.balanceOf(address(usdc), address(vault)), 80_000e6, "80% now earning yield");
        assertEq(vault.navWad(), navBefore, "moving money between buckets must not change NAV");
    }

    function test_navWad_growsAsYieldAccrues_evenWithoutASweepBack() public {
        vault.sweepIdleToYield(); // 80,000 USDC now at the adapter

        // Real yield accrues at the venue without anyone calling this vault.
        usdc.mint(address(pool), 500e6);
        pool.simulateYield(address(usdc), address(adapter), 500e6);

        // navWad() reads yieldSource.balanceOf live — no sweep-back needed
        // for the extra value to show up.
        assertEq(vault.navWad(), (100_000e18) + 500e18, "500 accrued USDC should show up as +$500 NAV");
    }

    function test_sweepYieldToIdle_pullsBackAndIsCappedAtWhatsAvailable() public {
        vault.sweepIdleToYield(); // 80,000 at the adapter, 20,000 idle

        vault.sweepYieldToIdle(30_000e6, 0);

        assertEq(vault.tvlA(), 50_000e6, "20,000 idle + 30,000 pulled back");
        assertEq(adapter.balanceOf(address(usdc), address(vault)), 50_000e6);
    }

    function test_withdraw_worksNormallyWhenYieldSourceIsUntouched() public {
        // Depositor withdraws before any sweep ever happens — the new
        // feature must not have changed ordinary behavior at all. Captured
        // before vm.prank so the prank lands on withdraw() itself, not on
        // this view call (an argument expression is evaluated — and would
        // consume the prank — before the outer call it's passed into).
        uint256 aliceShares = vault.sharesOf(alice);
        vm.prank(alice);
        (uint256 amountA,) = vault.withdraw(aliceShares);
        assertEq(amountA, 100_000e6);
    }

    /// @notice The bug this design has to avoid: if withdraw() only counted
    ///         tvlA (local) toward a depositor's pro-rata share, the swept
    ///         80,000 would become permanently unclaimable the moment alice
    ///         (the only depositor) redeems every share — nothing would be
    ///         left with a claim on it, forever. withdraw() has to count the
    ///         yield-parked portion too and auto-pull the shortfall.
    function test_withdraw_autoPullsFromYieldSourceWhenLocalIsShort() public {
        vault.sweepIdleToYield(); // 20,000 stays idle, 80,000 moves to the adapter

        uint256 aliceShares = vault.sharesOf(alice);
        vm.prank(alice);
        (uint256 amountA,) = vault.withdraw(aliceShares);

        assertEq(amountA, 100_000e6, "full entitlement paid: 20,000 local + 80,000 pulled from yield");
        assertEq(usdc.balanceOf(alice), 1_000_000e6, "alice ends up whole, exactly as if no sweep had happened");
        assertEq(adapter.balanceOf(address(usdc), address(vault)), 0, "nothing left stranded at the yield source");
        assertEq(vault.tvlA(), 0);
    }

    function test_yieldSourceUnset_sweepsAreNoOps() public {
        PairVault plainVault = new PairVault(
            address(usdc), address(weth), 6, 18, USDC_FEED, WETH_FEED, address(pyth), address(0), 1, address(this), treasury, address(0)
        );
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        plainVault.deposit(address(usdc), 1_000e6);

        plainVault.sweepIdleToYield(); // must not revert, must not do anything
        plainVault.sweepYieldToIdle(1e6, 1e6); // ditto

        assertEq(plainVault.tvlA(), 1_000e6, "untouched, no yield source configured");
    }
}
