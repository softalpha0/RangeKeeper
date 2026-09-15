// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Requires: forge install foundry-rs/forge-std Uniswap/v3-core
import {Script, console} from "forge-std/Script.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {ParamsRegistry} from "../src/ParamsRegistry.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

/// @notice Testnet deployment script. No canonical Uniswap v3 factory exists
///         on Monad testnet (only mainnet, chain 143 — see README, checked
///         directly via `eth_getCode`), so this deploys a real one itself,
///         exactly as any team building here before mainnet would. Run with:
///
///   forge script script/DeployRangekeeper.s.sol --rpc-url monad_testnet --broadcast
contract DeployRangekeeper is Script {
    // Pyth price feed contract, Monad testnet (README "Confirmed infra" table) —
    // unverified beyond that single fetch; confirm against docs.pyth.network before relying on it.
    address constant PYTH_TESTNET = 0x2880aB155794e7179c9eE2e38200202908C17B43;

    function run() external {
        vm.startBroadcast();

        // UniswapV3Factory predates this project's own Solidity version, so
        // it's deployed from its own compiled artifact rather than a direct
        // `new` — see script/DemoLoop.s.sol's identical local-simulation use
        // of the same mechanism.
        address factory = vm.deployCode("UniswapV3Factory.sol");
        console.log("UniswapV3Factory:", factory);

        ParamsRegistry paramsRegistry = new ParamsRegistry();
        console.log("ParamsRegistry:", address(paramsRegistry));

        VaultManager vaultManager = new VaultManager(address(paramsRegistry));
        console.log("VaultManager:", address(vaultManager));

        // VaultFactory.protocolTreasury sets itself to msg.sender internally
        // (see its constructor comment) — it'll be the deploying wallet for
        // now; there's no separate treasury contract or DAO yet, so
        // PairVault.collectFees()'s 15% treasury slice has to land somewhere
        // real. Replace before mainnet.
        // yieldSource: none — no lending market exists on Monad testnet right
        // now to point it at (see PairVault.sol's yieldSource comment).
        VaultFactory vaultFactory = new VaultFactory(address(vaultManager), PYTH_TESTNET, address(0));
        console.log("VaultFactory:", address(vaultFactory));

        vm.stopBroadcast();

        console.log("Next: IUniswapV3Factory(factory).createPool(tokenA, tokenB, fee), then pool.initialize(sqrtPriceX96),");
        console.log("      then VaultFactory.createVault(assetA, assetB, decimalsA, decimalsB, priceIdA, priceIdB, pool, tier),");
        console.log("      then VaultManager.setVaultForTier(tier, vault) -- admin-only, a separate explicit call,");
        console.log("      then ParamsRegistry.setTierParams(...) + execute() after the timelock,");
        console.log("      then fund the vault and call VaultManager.recenter(...) to open its first band.");
    }
}
