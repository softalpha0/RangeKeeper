// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title DemoTokenFaucet
/// @notice Public, rate-limited faucet for the two demo tokens this
///         project's testnet deployment uses in place of a real second
///         asset (see src/demo/DemoToken.sol). DemoToken.mint is owner-only
///         — without this, only the deploying wallet could ever hold any of
///         it, which meant a stranger connecting a wallet had literally
///         nothing to deposit and no way to get anything. This is what
///         actually lets someone try the deposit flow at all.
/// @dev Funded the plain way: the deployer (DemoToken's owner) mints a batch
///      directly to this contract's own address, and this contract just
///      redistributes what it already holds — no special minting privilege
///      lives here, and none is needed.
contract DemoTokenFaucet {
    IERC20Minimal public immutable tokenA;
    IERC20Minimal public immutable tokenB;
    uint256 public immutable claimAmountA;
    uint256 public immutable claimAmountB;
    uint256 public constant COOLDOWN = 1 days;

    mapping(address => uint256) public lastClaimedAt;

    error TooSoon(uint256 nextClaimAt);
    error FaucetEmpty();

    event Claimed(address indexed account, uint256 amountA, uint256 amountB);

    constructor(address _tokenA, address _tokenB, uint256 _claimAmountA, uint256 _claimAmountB) {
        tokenA = IERC20Minimal(_tokenA);
        tokenB = IERC20Minimal(_tokenB);
        claimAmountA = _claimAmountA;
        claimAmountB = _claimAmountB;
    }

    /// @notice Sends up to `claimAmountA`/`claimAmountB` of each demo token
    ///         to the caller, once per COOLDOWN per address.
    /// @dev Pays out whatever this contract actually still holds if it's
    ///      been drawn down below a full claim, rather than reverting
    ///      outright — a partial top-up is still useful to a tester, and an
    ///      empty faucet just needs refilling (mint more into this address),
    ///      never a code or redeploy change.
    function claim() external returns (uint256 paidA, uint256 paidB) {
        uint256 last = lastClaimedAt[msg.sender];
        if (last != 0 && block.timestamp < last + COOLDOWN) {
            revert TooSoon(last + COOLDOWN);
        }

        uint256 availableA = tokenA.balanceOf(address(this));
        uint256 availableB = tokenB.balanceOf(address(this));
        if (availableA == 0 && availableB == 0) revert FaucetEmpty();

        lastClaimedAt[msg.sender] = block.timestamp;

        paidA = claimAmountA > availableA ? availableA : claimAmountA;
        paidB = claimAmountB > availableB ? availableB : claimAmountB;

        if (paidA > 0) tokenA.transfer(msg.sender, paidA);
        if (paidB > 0) tokenB.transfer(msg.sender, paidB);

        emit Claimed(msg.sender, paidA, paidB);
    }

    /// @notice Seconds until `account` can claim again; 0 if they can claim now.
    function timeUntilNextClaim(address account) external view returns (uint256) {
        uint256 last = lastClaimedAt[account];
        if (last == 0) return 0;
        uint256 nextAt = last + COOLDOWN;
        return block.timestamp >= nextAt ? 0 : nextAt - block.timestamp;
    }
}
