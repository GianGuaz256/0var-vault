// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Minimal Pendle Router interface for MVP.
/// @dev The MVP strategy uses calldata passthrough + low-level call; this interface is primarily for typing/selectors.
interface IPendleRouter {
    /// @notice Execute multiple calls in a single transaction.
    /// @dev Present on many Pendle Router deployments; not all integrations need it.
    function multicall(
        bytes[] calldata data
    ) external payable returns (bytes[] memory results);
}
