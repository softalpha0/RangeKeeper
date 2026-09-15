// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IYieldSource} from "../interfaces/IYieldSource.sol";
import {IAaveV3Pool, IAaveV3PoolDataProvider} from "../interfaces/IAaveV3Pool.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title AaveV3YieldAdapter
/// @notice The "spare pocket" yield source (source paper §4.2), backed by a
///         real Aave V3 Pool. Multiple vaults, multiple assets — everything
///         funnels through this one contract, which deposits into Aave
///         on-behalf-of ITSELF (not the caller), then tracks each caller's
///         proportional claim internally. That's the piece a naive
///         `pool.supply(asset, amount, msg.sender, 0)` gets wrong: Aave would
///         mint the aToken straight to the calling vault, and this adapter
///         would then have no way to later call `pool.withdraw` on the
///         vault's behalf (Aave burns aTokens from whoever calls withdraw,
///         not from an address you name) — so custody has to live here,
///         with internal shares standing in for the aToken.
/// @dev Share accounting mirrors PairVault's own deposit/withdraw math
///      exactly (mint proportional to value added, redeem proportional to
///      value owned) — same convention, same reasoning, just one level down.
contract AaveV3YieldAdapter is IYieldSource {
    IAaveV3Pool public immutable pool;
    IAaveV3PoolDataProvider public immutable dataProvider;

    // asset -> account -> shares, and asset -> total shares outstanding.
    // Shares are this adapter's own unit, denominated 1:1 with `asset` at
    // first deposit — NOT the same number as Aave's own aToken balance,
    // though both track the same underlying value.
    mapping(address => mapping(address => uint256)) public sharesOf;
    mapping(address => uint256) public totalShares;

    error NothingToWithdraw();

    constructor(address _pool, address _dataProvider) {
        pool = IAaveV3Pool(_pool);
        dataProvider = IAaveV3PoolDataProvider(_dataProvider);
    }

    /// @dev See IYieldSource. Shares are computed from the aToken balance
    ///      BEFORE this deposit lands, so an account that deposited earlier
    ///      and has since accrued interest isn't diluted by a later deposit.
    function deposit(address asset, uint256 amount) external {
        if (amount == 0) return;
        IERC20Minimal(asset).transferFrom(msg.sender, address(this), amount);

        uint256 beforeBal = _aTokenBalance(asset);
        _approveIfNeeded(asset, amount);
        pool.supply(asset, amount, address(this), 0);

        uint256 total = totalShares[asset];
        uint256 shares = total == 0 ? amount : (amount * total) / beforeBal;
        sharesOf[asset][msg.sender] += shares;
        totalShares[asset] = total + shares;
    }

    /// @dev See IYieldSource. Caps `amount` at the caller's own redeemable
    ///      balance rather than reverting on an over-large request — a vault
    ///      sweeping "whatever's there" shouldn't have to read balanceOf
    ///      first just to avoid a revert.
    function withdraw(address asset, uint256 amount) external returns (uint256 withdrawn) {
        uint256 accountBal = balanceOf(asset, msg.sender);
        uint256 capped = amount > accountBal ? accountBal : amount;
        if (capped == 0) return 0;

        uint256 aBal = _aTokenBalance(asset);
        uint256 sharesToBurn = (capped * totalShares[asset]) / aBal;
        sharesOf[asset][msg.sender] -= sharesToBurn;
        totalShares[asset] -= sharesToBurn;

        withdrawn = pool.withdraw(asset, capped, msg.sender);
    }

    /// @dev See IYieldSource. Values `account`'s shares against Aave's own
    ///      live aToken balance, so interest that's accrued since the last
    ///      deposit/withdraw shows up immediately — no separate accrual
    ///      bookkeeping needed, since Aave's aToken already rebases for us.
    function balanceOf(address asset, address account) public view returns (uint256) {
        uint256 total = totalShares[asset];
        if (total == 0) return 0;
        return (sharesOf[asset][account] * _aTokenBalance(asset)) / total;
    }

    function _aTokenBalance(address asset) internal view returns (uint256) {
        (address aToken,,) = dataProvider.getReserveTokensAddresses(asset);
        return IERC20Minimal(aToken).balanceOf(address(this));
    }

    /// @dev Approves exactly what's needed for this call rather than
    ///      infinite-approving once — Aave's Pool is trusted infrastructure,
    ///      but there's no reason to leave a standing allowance bigger than
    ///      the transaction that needs it.
    function _approveIfNeeded(address asset, uint256 amount) internal {
        IERC20Minimal(asset).approve(address(pool), amount);
    }
}
