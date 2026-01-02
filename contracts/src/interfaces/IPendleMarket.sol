// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Minimal Pendle Market interface for MVP.
interface IPendleMarket {
    /// @notice Returns core tokens of the market.
    function readTokens()
        external
        view
        returns (address sy, address pt, address yt);
}
