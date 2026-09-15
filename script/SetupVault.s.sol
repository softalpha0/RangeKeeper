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

/// @notice Second-stage setup for the stack DeployRangekeeper.s.sol deploys:
///         mints two demo tokens, creates and initializes their pool, creates
///         a tier-1 vault for them, queues tier-1 risk params (2-day
///         timelock), and approves the new vault to pull both tokens from the
///         deployer for the deposit that follows. Deliberately does NOT
///         deposit or open a band here — both need a live Pyth price update,
///         which a static broadcast script can't fetch; see the accompanying
///         cast commands.
///
///   forge script script/SetupVault.s.sol --rpc-url https://testnet-rpc.monad.xyz --broadcast
///
/// Reads the already-deployed stack's addresses from env vars (see
/// DeployRangekeeper.s.sol's own console output for these).
contract SetupVault is Script {
    uint8 constant TIER = 1;
    bytes32 constant USDC_USD_FEED = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    function run() external {
        address factoryAddr = vm.envAddress("V3_FACTORY_ADDRESS");
        address vaultFactoryAddr = vm.envAddress("VAULT_FACTORY_ADDRESS");
        address vaultManagerAddr = vm.envAddress("VAULT_MANAGER_ADDRESS");
        address paramsRegistryAddr = vm.envAddress("PARAMS_REGISTRY_ADDRESS");

        vm.startBroadcast();

        DemoToken a = new DemoToken("Demo A", "DMOA", 18);
        DemoToken b = new DemoToken("Demo B", "DMOB", 18);
        (address token0, address token1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        console.log("token0:", token0);
        console.log("token1:", token1);

        DemoToken(token0).mint(msg.sender, 10_000e18);
        DemoToken(token1).mint(msg.sender, 10_000e18);

        address pool = IUniswapV3Factory(factoryAddr).createPool(token0, token1, 3000);
        IUniswapV3Pool(pool).initialize(uint160(1) << 96); // price = 1.0
        console.log("pool:", pool, "initialized at price 1.0");

        address vault = VaultFactory(vaultFactoryAddr).createVault(
            token0, token1, 18, 18, USDC_USD_FEED, USDC_USD_FEED, pool, TIER
        );
        console.log("vault:", vault);

        // Separate, explicit, admin-only call — VaultFactory doesn't do this
        // automatically (VaultManager.setVaultForTier is onlyAdmin; the
        // factory isn't the admin, the broadcasting deployer is).
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

        IERC20Approve(token0).approve(vault, type(uint256).max);
        IERC20Approve(token1).approve(vault, type(uint256).max);
        console.log("vault approved to pull both tokens from deployer");

        vm.stopBroadcast();

        console.log("");
        console.log("Next: depositWithPriceUpdate for both tokens, then VaultManager.recenterWithPriceUpdate to open the first band.");
    }
}
