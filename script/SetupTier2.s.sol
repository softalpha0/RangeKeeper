// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {VaultFactory} from "../src/VaultFactory.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {ParamsRegistry} from "../src/ParamsRegistry.sol";
import {IParamsRegistry} from "../src/interfaces/IParamsRegistry.sol";
import {DemoToken} from "../src/demo/DemoToken.sol";

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Sets up tier 2: a real pair, real testnet USDC against a freshly
///         minted demo token (matched 1:1 by value to whatever USDC the
///         deploying wallet actually holds) — the first vault whose value
///         isn't entirely demo tokens.
///
/// @dev USDC (6 decimals) and the demo token (18 decimals) need a
///      decimal-adjusted initial price, not a naive raw 1.0 — a raw pool
///      price of 1.0 only means equal *value* when both assets share
///      decimals. `_initialSqrtPriceX96` below derives the correct value
///      from each token's own decimals rather than hardcoding one direction,
///      since which asset lands as token0 depends on the addresses actually
///      assigned at deploy time. Uses its own fee tier (500/10) rather than
///      tier 1's (3000/60) — a different pair, priced differently, doesn't
///      need to share one.
///
///   forge script script/SetupTier2.s.sol --rpc-url https://testnet-rpc.monad.xyz --broadcast
contract SetupTier2 is Script {
    uint8 constant TIER = 2;
    uint24 constant FEE = 500;
    bytes32 constant USDC_USD_FEED = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    // Confirmed on-chain (symbol()="USDC", decimals()=6) — see README's
    // "Confirmed infra" table.
    address constant USDC_TESTNET = 0x534b2f3A21130d7a60830c2Df862319e593943A3;
    uint8 constant USDC_DECIMALS = 6;
    uint8 constant DEMO_DECIMALS = 18;

    function run() external {
        address factoryAddr = vm.envAddress("V3_FACTORY_ADDRESS");
        address vaultFactoryAddr = vm.envAddress("VAULT_FACTORY_ADDRESS");
        address vaultManagerAddr = vm.envAddress("VAULT_MANAGER_ADDRESS");
        address paramsRegistryAddr = vm.envAddress("PARAMS_REGISTRY_ADDRESS");
        // How much real USDC (raw, 6 decimals) the deploying wallet is
        // pairing — the demo token minted below matches it 1:1 by value.
        uint256 usdcAmountRaw = vm.envUint("TIER2_USDC_AMOUNT_RAW");

        vm.startBroadcast();

        DemoToken demo = new DemoToken("Demo Asset", "DMOA", DEMO_DECIMALS);
        console.log("demo token (DMOA):", address(demo));

        // 1:1 by value: usdcAmountRaw is in 6-decimal units, so scale up by
        // 1e12 to get the matching 18-decimal demo token amount.
        uint256 demoAmount = usdcAmountRaw * (10 ** (DEMO_DECIMALS - USDC_DECIMALS));
        demo.mint(msg.sender, demoAmount);
        console.log("minted matching demo tokens:", demoAmount);

        (address token0, address token1) = USDC_TESTNET < address(demo)
            ? (USDC_TESTNET, address(demo))
            : (address(demo), USDC_TESTNET);
        uint8 dec0 = token0 == USDC_TESTNET ? USDC_DECIMALS : DEMO_DECIMALS;
        uint8 dec1 = token1 == USDC_TESTNET ? USDC_DECIMALS : DEMO_DECIMALS;

        address pool = IUniswapV3Factory(factoryAddr).createPool(token0, token1, FEE);
        uint160 sqrtPriceX96 = _initialSqrtPriceX96(dec0, dec1);
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        console.log("pool:", pool, "initialized at decimal-adjusted 1:1, sqrtPriceX96:", sqrtPriceX96);

        address vault = VaultFactory(vaultFactoryAddr).createVault(
            token0, token1, dec0, dec1, USDC_USD_FEED, USDC_USD_FEED, pool, TIER
        );
        console.log("vault:", vault);

        VaultManager(payable(vaultManagerAddr)).setVaultForTier(TIER, vault);
        console.log("registered as tier", TIER);

        IParamsRegistry.TierParams memory p = IParamsRegistry.TierParams({
            zStar: 0.67449e18,
            kMax: 0,
            sigmaMax: 0.08e18,
            lcrMin: 0,
            mStar: 0,
            rSanityLow: 0.35e18,
            rSanityHigh: 0.65e18,
            version: 1
        });
        ParamsRegistry(paramsRegistryAddr).setTierParams(TIER, p);
        console.log("tier params queued; executable at:", block.timestamp + ParamsRegistry(paramsRegistryAddr).TIMELOCK_DELAY());

        IERC20Approve(USDC_TESTNET).approve(vault, type(uint256).max);
        IERC20Approve(address(demo)).approve(vault, type(uint256).max);
        console.log("vault approved to pull both tokens from deployer");

        vm.stopBroadcast();

        console.log("");
        console.log("Next: depositWithPriceUpdate for both tokens, then VaultManager.recenterWithPriceUpdate to open the first band.");
    }

    /// @dev sqrtPriceX96 for "1 unit of token0 == 1 unit of token1, in value"
    ///      when the two assets don't share decimals. Raw pool price is
    ///      token1_raw/token0_raw; equal *value* per raw unit needs that raw
    ///      price scaled by 10^(dec1-dec0), i.e. sqrtPriceX96 =
    ///      sqrt(10^(dec1-dec0)) * 2^96. Only ever called with |dec1-dec0| ==
    ///      12 here (USDC's 6 against a demo token's 18), which is always a
    ///      perfect square (10^6) — this is not a general-purpose sqrt.
    function _initialSqrtPriceX96(uint8 dec0, uint8 dec1) internal pure returns (uint160) {
        if (dec1 >= dec0) {
            uint256 half = (uint256(dec1 - dec0)) / 2;
            return uint160((10 ** half) * (1 << 96));
        } else {
            uint256 half = (uint256(dec0 - dec1)) / 2;
            return uint160((1 << 96) / (10 ** half));
        }
    }
}
