// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IYieldSource
/// @notice The "spare pocket" destination — wherever a vault's idle balance
///         earns a small yield while it waits (source paper §4.2). Deliberately
///         backend-agnostic: PairVault only ever calls deposit/withdraw/
///         balanceOf, so swapping Aave for a different money market later (or
///         plugging in a mock for tests) never touches PairVault's own code.
/// @dev Whatever implements this is expected to hold custody itself (e.g. an
///      Aave-style adapter holding aTokens under its own address) and account
///      for each caller's share internally — PairVault treats a nonzero
///      `balanceOf(asset, address(this))` as real, redeemable value, priced
///      straight into navWad() alongside idle and band value.
interface IYieldSource {
    /// @notice Pulls `amount` of `asset` from the caller (via transferFrom —
    ///         the caller must approve this contract first) and deposits it
    ///         into the underlying yield venue on the caller's behalf.
    function deposit(address asset, uint256 amount) external;

    /// @notice Withdraws up to `amount` of `asset` on behalf of `msg.sender`
    ///         and sends it back to them. Returns the amount actually
    ///         withdrawn, which may be less than requested if either the
    ///         caller's own balance or the venue's available liquidity is
    ///         smaller — never reverts on a partial fill, so a vault sweeping
    ///         funds back doesn't have to pre-compute an exact safe amount.
    function withdraw(address asset, uint256 amount) external returns (uint256 withdrawn);

    /// @notice `account`'s current redeemable balance of `asset`, in `asset`'s
    ///         own raw units — principal plus whatever yield has accrued so
    ///         far. Zero for an account that has never deposited.
    function balanceOf(address asset, address account) external view returns (uint256);
}
