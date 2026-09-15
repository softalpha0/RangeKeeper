// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

// This file exists only to make `forge build` actually compile the real
// UniswapV3Factory (and everything it pulls in) into `out/`, so
// `vm.deployCode("UniswapV3Factory.sol")` — used everywhere this project
// deploys its own factory, since no canonical one exists on Monad testnet —
// has an artifact to find. Nothing else in this repo imports v3-core's
// implementation contracts directly: they're pinned to a Solidity version
// this project's own ^0.8.26 code can't share a compilation unit with, so
// this lives in its own file, at its own pragma, compiled as its own
// self-contained unit. See any of the `vm.deployCode(...)` call sites for
// how the resulting artifact is actually used.
import {UniswapV3Factory} from "v3-core/contracts/UniswapV3Factory.sol";
