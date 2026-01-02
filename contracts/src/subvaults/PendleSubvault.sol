// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {
    IAccessControl
} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IFactoryEntity} from "mellow/interfaces/factories/IFactoryEntity.sol";
import {IVerifier} from "mellow/interfaces/permissions/IVerifier.sol";

import {CallModule} from "mellow/modules/CallModule.sol";
import {SubvaultModule} from "mellow/modules/SubvaultModule.sol";
import {VerifierModule} from "mellow/modules/VerifierModule.sol";

/// @notice Pendle strategy container implemented using Mellow's Subvault module pattern + Verifier gating.
/// @dev Deployed as a unique implementation (immutables) and used behind a proxy (initialize()).
contract PendleSubvault is IFactoryEntity, CallModule, SubvaultModule {
    /// @notice Role in the parent Vault required to call `enter/exit`.
    bytes32 public constant KEEPER_ROLE =
        keccak256("mellowpendle.PendleSubvault.KEEPER_ROLE");

    address public immutable ASSET;
    address public immutable PENDLE_ROUTER;
    address public immutable PENDLE_MARKET;
    address public immutable PENDLE_SY;
    address public immutable PENDLE_PT;
    address public immutable PENDLE_YT;
    address public immutable VAULT_IMMUTABLE;

    error InvalidVault(address expected, address provided);
    error Forbidden();
    error ProtectedToken(address token);

    modifier onlyKeeper() {
        if (!IAccessControl(vault()).hasRole(KEEPER_ROLE, msg.sender)) {
            revert Forbidden();
        }
        _;
    }

    constructor(
        address asset_,
        address router,
        address market,
        address sy,
        address pt,
        address yt,
        address vault
    ) VerifierModule("PendleSubvault", 1) SubvaultModule("PendleSubvault", 1) {
        ASSET = asset_;
        PENDLE_ROUTER = router;
        PENDLE_MARKET = market;
        PENDLE_SY = sy;
        PENDLE_PT = pt;
        PENDLE_YT = yt;
        VAULT_IMMUTABLE = vault;
    }

    /// @inheritdoc IFactoryEntity
    function initialize(bytes calldata initParams) external initializer {
        (address verifier_, address vault_) = abi.decode(
            initParams,
            (address, address)
        );
        if (vault_ != VAULT_IMMUTABLE) {
            revert InvalidVault(VAULT_IMMUTABLE, vault_);
        }
        __BaseModule_init();
        __VerifierModule_init(verifier_);
        __SubvaultModule_init(vault_);
        emit Initialized(initParams);
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    /// @notice Enters Pendle via Router calldata passthrough.
    /// @dev Assets must already be present in this Subvault (pushed from Vault).
    function enter(
        uint256 amountAsset,
        uint256 /*minLpOut*/,
        bytes calldata routerCalldata
    ) external nonReentrant onlyKeeper {
        // Approve exact amount, call router, reset approval.
        _verifyApprove(IERC20(ASSET), PENDLE_ROUTER, amountAsset);
        _verifyAndCall(PENDLE_ROUTER, 0, routerCalldata);
        _verifyApprove(IERC20(ASSET), PENDLE_ROUTER, 0);
    }

    /// @notice Exits Pendle via Router calldata passthrough and returns all resulting ASSET to the parent Vault.
    function exit(
        uint256 lpAmount,
        uint256 /*minAssetOut*/,
        bytes calldata routerCalldata
    ) external nonReentrant onlyKeeper {
        // Approve LP token (Pendle market token) if required by the provided calldata, call router, reset approval.
        _verifyApprove(IERC20(PENDLE_MARKET), PENDLE_ROUTER, lpAmount);
        _verifyAndCall(PENDLE_ROUTER, 0, routerCalldata);
        _verifyApprove(IERC20(PENDLE_MARKET), PENDLE_ROUTER, 0);

        // Return all liquid ASSET to Vault.
        uint256 bal = IERC20(ASSET).balanceOf(address(this));
        if (bal > 0) {
            _verifyErc20Transfer(IERC20(ASSET), vault(), bal);
        }
    }

    /// @notice Returns liquid ASSET balance. NAV for Pendle positions is handled by Mellow Oracle off-chain in later milestones.
    function totalHoldings() external view returns (uint256 assetEquivalent) {
        return IERC20(ASSET).balanceOf(address(this));
    }

    /// @notice Admin-only rescue for non-core tokens accidentally sent to the Subvault.
    function sweep(
        address token,
        address to,
        uint256 amount
    ) external nonReentrant {
        // Admin = Vault DEFAULT_ADMIN_ROLE holder.
        if (!IAccessControl(vault()).hasRole(bytes32(0), msg.sender)) {
            revert Forbidden();
        }
        if (
            token == ASSET ||
            token == PENDLE_MARKET ||
            token == PENDLE_SY ||
            token == PENDLE_PT ||
            token == PENDLE_YT
        ) {
            revert ProtectedToken(token);
        }
        // NOTE: rescue path intentionally does NOT use verifier gating to avoid needing per-token allowlists.
        require(IERC20(token).transfer(to, amount), "SWEEP_TRANSFER_FAILED");
    }

    // -----------------------------
    // Internal helpers (Verifier-gated calls)
    // -----------------------------

    function _onchainCompactPayload()
        internal
        pure
        returns (IVerifier.VerificationPayload memory payload)
    {
        payload.verificationType = IVerifier.VerificationType.ONCHAIN_COMPACT;
        payload.verificationData = bytes("");
        payload.proof = new bytes32[](0);
    }

    function _verifyAndCall(
        address where,
        uint256 value,
        bytes memory data
    ) internal returns (bytes memory response) {
        IVerifier.VerificationPayload memory payload = _onchainCompactPayload();
        // Gate on the Subvault itself (not the external caller), so the public `call()` executor is effectively disabled
        // unless explicitly granted in the Vault.
        verifier().verifyCall(address(this), where, value, data, payload);
        response = Address.functionCallWithValue(payable(where), data, value);
    }

    function _verifyApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        bytes memory res = _verifyAndCall(
            address(token),
            0,
            abi.encodeWithSelector(IERC20.approve.selector, spender, value)
        );
        if (res.length > 0) {
            require(abi.decode(res, (bool)), "APPROVE_FAILED");
        }
    }

    function _verifyErc20Transfer(
        IERC20 token,
        address to,
        uint256 value
    ) internal {
        bytes memory res = _verifyAndCall(
            address(token),
            0,
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        if (res.length > 0) {
            require(abi.decode(res, (bool)), "TRANSFER_FAILED");
        }
    }
}
