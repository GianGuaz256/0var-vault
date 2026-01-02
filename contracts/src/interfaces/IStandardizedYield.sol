// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Minimal subset of Pendle Standardized Yield (SY) interface for MVP.
/// @dev This is intentionally minimal; the MVP uses router calldata passthrough for most interactions.
interface IStandardizedYield {
    function assetInfo()
        external
        view
        returns (address assetAddress, uint8 assetDecimals);

    function deposit(
        address receiver,
        address tokenIn,
        uint256 amountTokenToDeposit,
        uint256 minSharesOut
    ) external payable returns (uint256 amountSharesOut);

    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external returns (uint256 amountTokenOut);
}
