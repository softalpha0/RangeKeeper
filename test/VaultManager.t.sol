// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {ParamsRegistry} from "../src/ParamsRegistry.sol";
import {IPairVault} from "../src/interfaces/IPairVault.sol";
import {IParamsRegistry} from "../src/interfaces/IParamsRegistry.sol";
import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/// @notice Minimal stand-in for a vault's pool — lets these tests set exactly
///         what `slot0()` reports, without a real deployed pool. Only
///         `slot0()` is ever called on this through `IUniswapV3Pool`, so
///         nothing else needs implementing.
contract MockV3Pool {
    uint160 public sqrtPriceX96Value;

    function setSqrtPriceX96(uint160 v) external {
        sqrtPriceX96Value = v;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96Value, 0, 0, 0, 0, 0, true);
    }
}

/// @notice Minimal IPairVault stand-in — lets these tests control exactly what
///         `band()`/`pool()` report and observe whether openBand/closeBand
///         were called, without a real deployed pool. The sanity-band math
///         itself (TickMath.getSqrtRatioAtTick on real ticks) is exercised
///         for real — only the pool interaction is mocked.
contract MockPairVault is IPairVault {
    IUniswapV3Pool public pool;
    int24 internal _tickLower;
    int24 internal _tickUpper;
    uint128 internal _liquidity;

    uint256 public openCallCount;
    uint256 public closeCallCount;

    constructor(address _pool) {
        pool = IUniswapV3Pool(_pool);
    }

    function setBand(int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        _tickLower = tickLower;
        _tickUpper = tickUpper;
        _liquidity = liquidity;
    }

    function band() external view returns (int24, int24, uint128) {
        return (_tickLower, _tickUpper, _liquidity);
    }

    function openBand(int24 tickLower, int24 tickUpper, uint256, uint256) external returns (uint128) {
        openCallCount++;
        _tickLower = tickLower;
        _tickUpper = tickUpper;
        _liquidity = 777e18;
        return 777e18;
    }

    function closeBand() external returns (uint256, uint256) {
        closeCallCount++;
        _liquidity = 0;
        return (0, 0);
    }

    function pushPriceUpdate(bytes[] calldata) external payable {}

    // Unused by this suite — see test/PairVaultBand.t.sol / VaultManagerRecenter.t.sol.
    function deposit(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function depositFor(address, uint256, address) external pure returns (uint256) {
        return 0;
    }

    function depositWithPriceUpdate(address, uint256, bytes[] calldata) external payable returns (uint256) {
        return 0;
    }

    function withdraw(uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function collectFees() external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function utilization() external pure returns (uint256) {
        return 0;
    }

    function navWad() external pure returns (uint256) {
        return 1_000_000e18;
    }

    function tvl() external pure returns (uint256) {
        return 1_000_000e18;
    }

    function valueOfAssetA(uint256 amountRaw) external pure returns (uint256) {
        return amountRaw;
    }

    function valueOfAssetB(uint256 amountRaw) external pure returns (uint256) {
        return amountRaw;
    }
}

/// @notice Exercises VaultManager's on-chain re-validation: a keeper cannot
///         fabricate an urgent-looking proof for a band the chain can see is
///         actually centered, cannot thrash a band faster than the cooldown,
///         and cannot resume from a circuit-breaker pause while still volatile.
contract VaultManagerTest is Test {
    ParamsRegistry paramsRegistry;
    VaultManager vaultManager;
    MockPairVault vault;
    MockV3Pool mockPool;
    uint8 constant TIER = 1;

    // Real ticks -> real sqrt prices via TickMath: tick -600 ~= sqrtP 0.9704,
    // tick 600 ~= sqrtP 1.0304 (same numbers the math spec's worked example uses).
    int24 constant TICK_LO = -600;
    int24 constant TICK_HI = 600;
    uint256 constant SQRT_CENTERED = 1.000e18; // r ~= 0.49, comfortably centered
    uint256 constant SQRT_NEAR_EDGE = 1.020e18; // r ~= 0.83, genuinely near the upper edge

    function setUp() public {
        paramsRegistry = new ParamsRegistry();
        vaultManager = new VaultManager(address(paramsRegistry));
        mockPool = new MockV3Pool();
        vault = new MockPairVault(address(mockPool));

        vaultManager.setVaultForTier(TIER, address(vault));

        IParamsRegistry.TierParams memory p = IParamsRegistry.TierParams({
            zStar: 1.036e18, // theta*=0.30 equivalent, per math spec §7
            kMax: 0,
            sigmaMax: 0.08e18,
            lcrMin: 0,
            mStar: 0,
            rSanityLow: 0.35e18,
            rSanityHigh: 0.65e18,
            version: 1
        });
        paramsRegistry.setTierParams(TIER, p);
        vm.warp(block.timestamp + paramsRegistry.TIMELOCK_DELAY() + 1);
        paramsRegistry.execute(TIER);
    }

    /// @dev Converts a WAD-scaled sqrt price (e.g. 1.02e18) into the raw
    ///      Q64.96 form `slot0()` actually returns, so the mock pool reports
    ///      what RiskMath.sqrtPriceX96ToWad will convert straight back.
    function _toSqrtX96(uint256 sqrtPWad) internal pure returns (uint160) {
        return uint160((sqrtPWad << 96) / 1e18);
    }

    function _calmProof() internal pure returns (bytes memory) {
        // d_min=0.047, sigma*sqrt(T)=0.059 -> ratio 0.79 < zStar=1.036 -> triggered; sigma 0.05 <= sigmaMax
        return abi.encode(uint256(0.047e18), uint256(0.059e18), uint256(0.05e18));
    }

    function _volatileProof() internal pure returns (bytes memory) {
        return abi.encode(uint256(0.047e18), uint256(0.059e18), uint256(0.15e18));
    }

    function test_recenter_opensFirstBandUnconditionally() public {
        // vault reports no band yet (liquidity 0, default) -- no trigger/sanity
        // check applies, recenter must just open one.
        vaultManager.recenter(TIER, TICK_LO, TICK_HI, 1_000e18, 1_000e18, _calmProof());
        assertEq(vault.openCallCount(), 1);
        assertEq(vault.closeCallCount(), 0);
    }

    function test_recenter_revertsWhenChainSaysBandIsCentered() public {
        vault.setBand(TICK_LO, TICK_HI, 500e18);
        mockPool.setSqrtPriceX96(_toSqrtX96(SQRT_CENTERED));

        vm.expectRevert(VaultManager.OutOfSanityBand.selector);
        vaultManager.recenter(TIER, TICK_LO, TICK_HI, 1_000e18, 1_000e18, _calmProof());
        assertEq(vault.closeCallCount(), 0, "must not have touched the band");
    }

    function test_recenter_succeedsWhenChainAgreesBandIsNearEdge() public {
        vault.setBand(TICK_LO, TICK_HI, 500e18);
        mockPool.setSqrtPriceX96(_toSqrtX96(SQRT_NEAR_EDGE));

        vaultManager.recenter(TIER, TICK_LO + 60, TICK_HI + 60, 1_000e18, 1_000e18, _calmProof());
        assertEq(vault.closeCallCount(), 1);
        assertEq(vault.openCallCount(), 1);
    }

    function test_recenter_revertsWhenTooSoon() public {
        vault.setBand(TICK_LO, TICK_HI, 500e18);
        mockPool.setSqrtPriceX96(_toSqrtX96(SQRT_NEAR_EDGE));

        vaultManager.recenter(TIER, TICK_LO, TICK_HI, 1_000e18, 1_000e18, _calmProof());

        // Immediately try again -- still within the cooldown.
        vm.expectRevert(VaultManager.TooSoon.selector);
        vaultManager.recenter(TIER, TICK_LO, TICK_HI, 1_000e18, 1_000e18, _calmProof());
    }

    function test_recenter_pausesOnHighVolatility_thenRequiresCalmToResume() public {
        vault.setBand(TICK_LO, TICK_HI, 500e18);
        mockPool.setSqrtPriceX96(_toSqrtX96(SQRT_NEAR_EDGE));

        vaultManager.recenter(TIER, TICK_LO, TICK_HI, 1_000e18, 1_000e18, _volatileProof());
        assertEq(vault.closeCallCount(), 1, "must have closed the band");
        assertEq(vault.openCallCount(), 0, "must NOT have reopened -- circuit breaker");
        assertTrue(vaultManager.paused(TIER));

        // Still volatile -> refuses to resume.
        vm.warp(block.timestamp + vaultManager.MIN_RECENTER_INTERVAL() + 1);
        vm.expectRevert(VaultManager.StillPaused.selector);
        vaultManager.recenter(TIER, TICK_LO, TICK_HI, 1_000e18, 1_000e18, _volatileProof());

        // Calm again -> resumes, opens a fresh band, clears the pause.
        vaultManager.recenter(TIER, TICK_LO, TICK_HI, 1_000e18, 1_000e18, _calmProof());
        assertEq(vault.openCallCount(), 1);
        assertFalse(vaultManager.paused(TIER));
    }

    // ------------------------------------------------------------------
    // admin gating on setVaultForTier — previously callable by anyone,
    // which meant any address could hijack a tier's registered vault.
    // ------------------------------------------------------------------

    function test_setVaultForTier_revertsForNonAdmin() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(VaultManager.NotAdmin.selector);
        vaultManager.setVaultForTier(TIER, address(0xBAD));
    }

    function test_admin_isTheDeployer() public {
        assertEq(vaultManager.admin(), address(this));
    }
}
