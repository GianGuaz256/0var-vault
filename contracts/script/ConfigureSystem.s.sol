// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vault} from "mellow/vaults/Vault.sol";
import {FeeManager} from "mellow/managers/FeeManager.sol";
import {RiskManager} from "mellow/managers/RiskManager.sol";

import {IOracle} from "mellow/interfaces/oracles/IOracle.sol";

import {IVerifier} from "mellow/interfaces/permissions/IVerifier.sol";
import {IVerifierModule} from "mellow/interfaces/modules/IVerifierModule.sol";

import {IPendleRouter} from "contracts/src/interfaces/IPendleRouter.sol";

/// @notice Post-deploy configuration for the MVP system (roles, limits, oracle seed, verifier allowlist).
contract ConfigureSystem is Script {
    // Verifier roles (checked on Vault)
    bytes32 internal constant VERIFIER_ALLOW_CALL_ROLE =
        keccak256("permissions.Verifier.ALLOW_CALL_ROLE");
    bytes32 internal constant VERIFIER_CALLER_ROLE =
        keccak256("permissions.Verifier.CALLER_ROLE");

    function run() external {
        uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (pk == 0) vm.startBroadcast();
        else vm.startBroadcast(pk);

        address vaultAddr = vm.envAddress("VAULT");
        Vault vault = Vault(payable(vaultAddr));

        address wstETH = vm.envAddress("WSTETH");
        address pendleMarket = vm.envAddress("PENDLE_MARKET");
        address pendleSubvault = vm.envAddress("PENDLE_SUBVAULT");

        // --- Fee manager base asset ---
        FeeManager fm = FeeManager(address(vault.feeManager()));
        fm.setBaseAsset(vaultAddr, wstETH);

        // --- Risk manager subvault limits/allowed assets ---
        RiskManager rm = RiskManager(address(vault.riskManager()));
        address[] memory allowed = new address[](2);
        allowed[0] = wstETH;
        allowed[1] = pendleMarket;
        rm.allowSubvaultAssets(pendleSubvault, allowed);
        rm.setSubvaultLimit(pendleSubvault, int256(type(int128).max));

        // --- Oracle seed report so signature queues can validate prices ---
        IOracle oracle = vault.oracle();
        IOracle.Report[] memory reports = new IOracle.Report[](1);
        reports[0] = IOracle.Report({asset: wstETH, priceD18: 1 ether});
        oracle.submitReports(reports);
        IOracle.DetailedReport memory r = oracle.getReport(wstETH);
        oracle.acceptReport(wstETH, r.priceD18, r.timestamp);

        // --- Verifier allowlist for the PendleSubvault ---
        IVerifier verifier = IVerifier(
            address(IVerifierModule(pendleSubvault).verifier())
        );

        // Grant Verifier.CALLER_ROLE to the subvault itself (our PendleSubvault verifies as address(this))
        vault.grantRole(VERIFIER_CALLER_ROLE, pendleSubvault);

        // Allow minimal calls (who = subvault)
        address pendleRouter = vm.envAddress("PENDLE_ROUTER");
        IVerifier.CompactCall[] memory calls = new IVerifier.CompactCall[](4);
        calls[0] = IVerifier.CompactCall({
            who: pendleSubvault,
            where: wstETH,
            selector: IERC20.approve.selector
        });
        calls[1] = IVerifier.CompactCall({
            who: pendleSubvault,
            where: pendleMarket,
            selector: IERC20.approve.selector
        });
        calls[2] = IVerifier.CompactCall({
            who: pendleSubvault,
            where: wstETH,
            selector: IERC20.transfer.selector
        });
        calls[3] = IVerifier.CompactCall({
            who: pendleSubvault,
            where: pendleRouter,
            selector: IPendleRouter.multicall.selector
        });

        // Deployer must have permissions.Verifier.ALLOW_CALL_ROLE in the vault (set in DeploySystem role holders)
        verifier.allowCalls(calls);

        vm.stopBroadcast();
    }
}
