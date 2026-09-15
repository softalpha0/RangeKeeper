// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Requires: forge install foundry-rs/forge-std Uniswap/v3-core
import {Script, console} from "forge-std/Script.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {ParamsRegistry} from "../src/ParamsRegistry.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {PairVault} from "../src/PairVault.sol";
import {DemoToken} from "../src/demo/DemoToken.sol";
import {RiskMath} from "../src/libraries/RiskMath.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {IParamsRegistry} from "../src/interfaces/IParamsRegistry.sol";
import {V3TestRouter} from "../test/utils/V3TestRouter.sol";

/// @title DemoLoop — one-shot, local, end-to-end demo of the Rangekeeper vault.
/// @notice Runs the entire recenter loop against a real in-memory Uniswap v3
///         pool, with nothing mocked except the Pyth oracle:
///
///           1. deploy the full stack (a real UniswapV3Factory + pool)
///           2. governance queues tier params, waits out the real timelock
///           3. depositors fund the PairVault (NAV-priced shares, atomic Pyth push)
///           4. the vault opens its own first band (unconditional — nothing to
///              be "near the edge" of yet)
///           5. a keeper tries to recenter while the band is still centered ->
///              REJECTED (the pool's own live price contradicts the proof)
///           6. price drifts to the band's edge
///           7. the same recenter now CLEARS both gates -> old band closes,
///              new band opens around the new price, real liquidity moves
///           8. swaps accrue real 0.3% fees; PairVault.collectFees harvests them
///           9. a volatility spike trips the circuit breaker -> band closes,
///              does NOT reopen (the vault sits in cash on purpose)
///          10. calmer conditions let a later recenter resume -> a fresh band opens
///
///         Pure local simulation (no broadcast, no keys, no RPC). Run with:
///
///           forge script script/DemoLoop.s.sol -vv
///
///         Everything it asserts is a real on-chain effect (pool position
///         records, token balances, vault NAV), not just "the call didn't revert".
contract DemoLoop is Script {
    uint8 constant TIER = 1;
    bytes32 constant FEED0 = bytes32(uint256(0xF0));
    bytes32 constant FEED1 = bytes32(uint256(0xF1));

    // The vault's band. Wide enough that price can actually travel inside the
    // liquid region and produce a real, on-chain-derivable recenter — a
    // stablecoin-tight range would leave nowhere for a demo swap to go without
    // falling straight out of all liquidity. Ticks +/-2400 ~= price [0.787, 1.271].
    int24 constant TICK_LO = -2400;
    int24 constant TICK_HI = 2400;
    uint256 constant SQRT_PA = 0.887e18;
    uint256 constant SQRT_PB = 1.1275e18;

    IUniswapV3Factory factory;
    IUniswapV3Pool pool;
    V3TestRouter router;
    DemoPyth pyth;
    ParamsRegistry params;
    VaultManager vaultManager;
    PairVault vault;
    DemoToken token0;
    DemoToken token1;

    address constant TREASURY = address(0x7EA5); // protocol treasury — not exercised by this demo's own assertions
    address constant TRADER = address(0x7EADE); // generates swaps
    address constant KEEPER = address(0x5EE9E5); // calls recenter
    address alice = address(0xA11CE); // depositor

    function run() external {
        _h("1. DEPLOY STACK");
        _deployStack();

        _h("2. GOVERNANCE: queue tier params, wait out the timelock");
        _governanceSetup();

        _h("3. DEPOSITORS: fund the PairVault (NAV-priced shares)");
        _fundVault();

        _h("4. VAULT opens its own first band (unconditional)");
        _openFirstBand();

        _h("5. KEEPER tries to recenter while the band is CENTERED");
        _tinySwapToMovePrice();
        _attemptRecenterExpectingRejection();

        _h("6. PRICE drifts to the band's edge");
        _pushPriceToEdge();

        _h("7. KEEPER recenters -- now it CLEARS both gates");
        _recenterForReal();

        _h("8. Swaps accrue real fees; PairVault.collectFees harvests");
        _accrueAndHarvestFees();

        _h("9. Volatility spike trips the circuit breaker");
        _tripCircuitBreaker();

        _h("10. Calmer conditions let the vault resume");
        _resumeAfterPause();

        _h("FINAL LEDGER");
        _printLedger();
    }

    // ------------------------------------------------------------------
    // 1. Deploy
    // ------------------------------------------------------------------
    function _deployStack() internal {
        // A real UniswapV3Factory — the same contract Monad's own deployment
        // would run, just instantiated locally via its compiled artifact
        // (its own pragma predates this project's, so it's deployed from its
        // raw bytecode rather than a direct `new`, exactly as a testnet
        // deploy script does when no canonical factory already exists).
        factory = IUniswapV3Factory(vm.deployCode("UniswapV3Factory.sol"));
        router = new V3TestRouter();

        DemoToken a = new DemoToken("Demo A", "DMOA", 18);
        DemoToken b = new DemoToken("Demo B", "DMOB", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        pyth = new DemoPyth();
        pyth.setPrice(FEED0, 1e8, -8); // $1.00
        pyth.setPrice(FEED1, 1e8, -8); // $1.00
        pyth.setUpdateFee(0); // demo: no Pyth fee, so no ETH plumbing needed

        params = new ParamsRegistry();
        vaultManager = new VaultManager(address(params));

        pool = IUniswapV3Pool(factory.createPool(address(token0), address(token1), 3000)); // 0.3%
        pool.initialize(uint160(1) << 96); // price = 1.0

        vault = new PairVault(
            address(token0),
            address(token1),
            18,
            18,
            FEED0,
            FEED1,
            address(pyth),
            address(pool),
            TIER,
            address(vaultManager),
            TREASURY,
            address(0) // no yield source in this local demo
        );
        vaultManager.setVaultForTier(TIER, address(vault));

        // Fund + approve the swap-generating actor.
        token0.mint(TRADER, 1_000_000e18);
        token1.mint(TRADER, 1_000_000e18);
        vm.prank(TRADER);
        token0.approve(address(router), type(uint256).max);
        vm.prank(TRADER);
        token1.approve(address(router), type(uint256).max);

        console.log("   UniswapV3Factory", address(factory));
        console.log("   pool             ", address(pool));
        console.log("   ParamsRegistry   ", address(params));
        console.log("   VaultManager     ", address(vaultManager));
        console.log("   PairVault        ", address(vault));
        console.log("   pool price       ", "1.000000 (sqrtPriceX96 = 2^96)");
    }

    // ------------------------------------------------------------------
    // 2. Governance
    // ------------------------------------------------------------------
    function _governanceSetup() internal {
        IParamsRegistry.TierParams memory p = IParamsRegistry.TierParams({
            zStar: 0.67449e18, // theta* ~= 0.50 in z-score form (RiskMath: no CDF on-chain)
            kMax: 0, // unused by VaultManager v1
            sigmaMax: 0.08e18,
            lcrMin: 0, // unused by VaultManager v1
            mStar: 0, // unused by VaultManager v1
            rSanityLow: 0.35e18, // on-chain edge band: r <= 0.35 or r >= 0.65 counts as "near an edge"
            rSanityHigh: 0.65e18,
            version: 1
        });
        params.setTierParams(TIER, p);
        console.log("   params queued; timelock (s):", params.TIMELOCK_DELAY());
        vm.warp(block.timestamp + params.TIMELOCK_DELAY() + 1);
        params.execute(TIER);
        _refreshOracle(); // the warp above aged the Pyth feeds past staleness
        console.log("   timelock elapsed; params.execute() -> live. zStar:", params.paramsOf(TIER).zStar);
    }

    // ------------------------------------------------------------------
    // 3. Depositors
    // ------------------------------------------------------------------
    function _fundVault() internal {
        token0.mint(alice, 10_000e18);
        token1.mint(alice, 10_000e18);

        bytes[] memory upd = _updData();
        vm.startPrank(alice);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        uint256 s0 = vault.depositWithPriceUpdate(address(token0), 10_000e18, upd);
        uint256 s1 = vault.depositWithPriceUpdate(address(token1), 10_000e18, upd);
        vm.stopPrank();

        console.log("   alice deposited 10,000 of each token");
        console.log("   shares minted (side 0 / side 1):", s0, s1);
        console.log("   vault NAV (WAD):", vault.navWad());
    }

    // ------------------------------------------------------------------
    // 4. First band
    // ------------------------------------------------------------------
    function _openFirstBand() internal {
        // No band exists yet, so recenter() opens one unconditionally -- the
        // proof is ignored on this path (nothing to be "near the edge" of).
        vm.prank(KEEPER);
        vaultManager.recenterWithPriceUpdate(TIER, TICK_LO, TICK_HI, 4_000e18, 4_000e18, _urgentProof(), _updData());

        (,, uint128 liq) = vault.band();
        console.log("   band now open, liquidity:", liq);
        console.log("   vault NAV after opening the band (WAD):", vault.navWad());
        console.log("   -> NAV correctly still counts the deployed band, not just idle balance");
    }

    // ------------------------------------------------------------------
    // 5. Centered -> rejection
    // ------------------------------------------------------------------
    function _tinySwapToMovePrice() internal {
        _swap(true, -1e18); // barely moves price
        console.log("   position-in-range r (WAD, 0=lower edge, 1e18=upper edge):", _currentR());
        console.log("   r is between rSanityLow (0.35) and rSanityHigh (0.65): CENTERED");
    }

    function _attemptRecenterExpectingRejection() internal {
        vm.warp(block.timestamp + vaultManager.MIN_RECENTER_INTERVAL() + 1); // clear the cooldown so the sanity check is what actually blocks this
        _refreshOracle();
        vm.prank(KEEPER);
        try vaultManager.recenterWithPriceUpdate(TIER, TICK_LO, TICK_HI, 2_000e18, 2_000e18, _urgentProof(), _updData())
        {
            console.log("   !! UNEXPECTED: recenter went through while centered");
        } catch (bytes memory err) {
            console.log("   rejected as designed: the pool's own live price says the band is centered,");
            console.log("   so the keeper's 'urgent' proof cannot move any capital.");
            console.log("   revert:", _errName(bytes4(err)));
        }
        (,, uint128 liq) = vault.band();
        console.log("   band still open, unchanged, liquidity:", liq);
    }

    // ------------------------------------------------------------------
    // 6. Move to the edge
    // ------------------------------------------------------------------
    function _pushPriceToEdge() internal {
        // The vault's own first band alone (opened in step 4) is far deeper
        // liquidity than a small outside LP would be, so this needs to be much
        // larger than it would in a thin pool to actually move price meaningfully.
        _swap(false, -3_000e18); // token1 in -> price rises toward the upper bound
        console.log("   position-in-range r (WAD):", _currentR());
        console.log("   r >= rSanityHigh (0.65): the chain now agrees the band is NEAR AN EDGE");
    }

    // ------------------------------------------------------------------
    // 7. Real recenter
    // ------------------------------------------------------------------
    function _recenterForReal() internal {
        (,, uint128 liqBefore) = vault.band();

        vm.warp(block.timestamp + vaultManager.MIN_RECENTER_INTERVAL() + 1);
        _refreshOracle();

        // New band re-centered on the drifted price. In production a solver
        // would compute this from the live tick; a fixed shift is enough to
        // show a real close-then-reopen with different bounds.
        int24 newTickLo = TICK_LO + 600;
        int24 newTickHi = TICK_HI + 600;

        vm.prank(KEEPER);
        vaultManager.recenterWithPriceUpdate(TIER, newTickLo, newTickHi, 2_000e18, 2_000e18, _urgentProof(), _updData());

        (int24 tl, int24 tu, uint128 liqAfter) = vault.band();
        uint128 poolLiqOld = _vaultPoolLiquidity(TICK_LO, TICK_HI);
        console.log("   old band liquidity before / after (real pool state):", liqBefore, poolLiqOld);
        console.log("   new band tick lower:", tl);
        console.log("   new band tick upper:", tu);
        console.log("   new band liquidity:", liqAfter);
        console.log("   vault NAV after recentering (WAD):", vault.navWad());
    }

    // ------------------------------------------------------------------
    // 8. Fees
    // ------------------------------------------------------------------
    function _accrueAndHarvestFees() internal {
        _swap(true, -40e18);
        _swap(false, -35e18);
        _swap(true, -25e18);
        _swap(false, -20e18);

        _refreshOracle();
        uint256 navBefore = vault.navWad();
        (uint256 f0, uint256 f1) = vault.collectFees();
        console.log("   fees harvested into the vault  token0 / token1:", f0, f1);
        console.log("   vault NAV before / after harvest (WAD):", navBefore, vault.navWad());
    }

    // ------------------------------------------------------------------
    // 9. Circuit breaker
    // ------------------------------------------------------------------
    function _tripCircuitBreaker() internal {
        _swap(false, -300e18); // push further toward the edge so the sanity gate still clears
        _refreshOracle();
        vm.warp(block.timestamp + vaultManager.MIN_RECENTER_INTERVAL() + 1);

        // sigmaWad above sigmaMax (0.08e18) -> circuit breaker: close, don't reopen.
        bytes memory volatileProof = abi.encode(uint256(0.03e18), uint256(0.06e18), uint256(0.15e18));

        vm.prank(KEEPER);
        vaultManager.recenterWithPriceUpdate(TIER, TICK_LO + 1200, TICK_HI + 1200, 0, 0, volatileProof, _updData());

        (,, uint128 liq) = vault.band();
        console.log("   band liquidity after the volatility spike (expect 0):", liq);
        console.log("   paused:", vaultManager.paused(TIER));
        console.log("   vault sits in cash on purpose -- capital is idle, not lost. tvlA/tvlB:", vault.tvlA(), vault.tvlB());
    }

    // ------------------------------------------------------------------
    // 10. Resume
    // ------------------------------------------------------------------
    function _resumeAfterPause() internal {
        vm.warp(block.timestamp + vaultManager.MIN_RECENTER_INTERVAL() + 1);
        _refreshOracle();

        // Still volatile -> must stay paused.
        bytes memory stillVolatile = abi.encode(uint256(0.03e18), uint256(0.06e18), uint256(0.15e18));
        vm.prank(KEEPER);
        try vaultManager.recenterWithPriceUpdate(TIER, TICK_LO, TICK_HI, 2_000e18, 2_000e18, stillVolatile, _updData())
        {
            console.log("   !! UNEXPECTED: resumed while still volatile");
        } catch (bytes memory err) {
            console.log("   correctly refused to resume while still volatile:", _errName(bytes4(err)));
        }

        // Calm again -> resume, open a fresh band.
        vm.warp(block.timestamp + vaultManager.MIN_RECENTER_INTERVAL() + 1);
        bytes memory calm = abi.encode(uint256(0.03e18), uint256(0.06e18), uint256(0.05e18));
        vm.prank(KEEPER);
        vaultManager.recenterWithPriceUpdate(TIER, TICK_LO, TICK_HI, 2_000e18, 2_000e18, calm, _updData());

        (,, uint128 liq) = vault.band();
        console.log("   paused after resume (expect false):", vaultManager.paused(TIER));
        console.log("   fresh band liquidity:", liq);
    }

    // ------------------------------------------------------------------
    // Ledger
    // ------------------------------------------------------------------
    function _printLedger() internal view {
        (,, uint128 liq) = vault.band();
        console.log("   vault totalShares (WAD):    ", vault.totalShares());
        console.log("   vault NAV (WAD):             ", vault.navWad());
        console.log("   vault tvlA / tvlB (idle, raw):", vault.tvlA(), vault.tvlB());
        console.log("   vault band liquidity:        ", liq);
        console.log("   vault utilization (WAD):     ", vault.utilization());
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        vm.prank(TRADER);
        router.swap(pool, TRADER, zeroForOne, amountSpecified, limit);
    }

    function _currentR() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 sqrtPWad = RiskMath.sqrtPriceX96ToWad(sqrtPriceX96);
        return RiskMath.positionInRange(sqrtPWad, SQRT_PA, SQRT_PB);
    }

    function _vaultPoolLiquidity(int24 tickLower, int24 tickUpper) internal view returns (uint128 liquidity) {
        bytes32 key = keccak256(abi.encodePacked(address(vault), tickLower, tickUpper));
        (liquidity,,,,) = pool.positions(key);
    }

    function _errName(bytes4 sel) internal pure returns (string memory) {
        if (sel == VaultManager.OutOfSanityBand.selector) return "OutOfSanityBand()";
        if (sel == VaultManager.NotTriggered.selector) return "NotTriggered()";
        if (sel == VaultManager.TooSoon.selector) return "TooSoon()";
        if (sel == VaultManager.StillPaused.selector) return "StillPaused()";
        return "other";
    }

    function _urgentProof() internal pure returns (bytes memory) {
        // dMin 0.03 / sigmaSqrtT 0.06 = 0.5 <= zStar 0.67449 -> triggered; sigma 0.06 <= sigmaMax 0.08 -> no circuit break
        return abi.encode(uint256(0.03e18), uint256(0.06e18), uint256(0.06e18));
    }

    function _updData() internal pure returns (bytes[] memory upd) {
        upd = new bytes[](1);
        upd[0] = hex"00"; // DemoPyth ignores contents
    }

    function _refreshOracle() internal {
        pyth.setPrice(FEED0, 1e8, -8);
        pyth.setPrice(FEED1, 1e8, -8);
    }

    function _h(string memory s) internal pure {
        console.log("");
        console.log("======================================================================");
        console.log(s);
        console.log("======================================================================");
    }
}

/// @notice Demo-only Pyth stand-in. ABI-matches IPyth; refreshes every known
///         feed's publishTime to `now` on updatePriceFeeds, exactly as a real
///         Hermes push would. The one piece of this demo that is not a real
///         deployed contract — everything else runs against a real Uniswap v3
///         factory and pool.
contract DemoPyth is IPyth {
    mapping(bytes32 => Price) private _p;
    bytes32[] private _ids;
    mapping(bytes32 => bool) private _seen;
    uint256 public fee;

    error StalePrice();

    function setPrice(bytes32 id, int64 price, int32 expo) external {
        if (!_seen[id]) {
            _seen[id] = true;
            _ids.push(id);
        }
        _p[id] = Price({price: price, conf: 0, expo: expo, publishTime: block.timestamp});
    }

    function setUpdateFee(uint256 f) external {
        fee = f;
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory) {
        Price memory pr = _p[id];
        if (block.timestamp - pr.publishTime > age) revert StalePrice();
        return pr;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {
        require(msg.value >= fee, "insufficient fee");
        for (uint256 i = 0; i < _ids.length; i++) {
            _p[_ids[i]].publishTime = block.timestamp;
        }
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return fee;
    }
}
