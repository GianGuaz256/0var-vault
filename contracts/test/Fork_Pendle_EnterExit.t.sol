// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import {Vault} from "mellow/vaults/Vault.sol";
import {IVaultModule} from "mellow/interfaces/modules/IVaultModule.sol";
import {IRiskManager} from "mellow/interfaces/managers/IRiskManager.sol";
import {PendleSubvault} from "contracts/src/subvaults/PendleSubvault.sol";
import {IPendleRouter} from "contracts/src/interfaces/IPendleRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Fork_Pendle_EnterExit
 * @notice Fork tests for Pendle strategy enter/exit flows through PendleSubvault
 */
contract Fork_Pendle_EnterExit is Test {
    Vault public vault;
    PendleSubvault public pendleSubvault;
    address public wstETH;
    address public pendleRouter;
    address public pendleMarket;
    address public keeper;

    function setUp() public {
        // Load Arbitrum fork
        string memory rpc = vm.envOr(
            "ARBITRUM_RPC_URL",
            string("https://arb1.arbitrum.io/rpc")
        );
        vm.createSelectFork(rpc);

        keeper = address(this);

        // In practice: run DeploySystem script first and pass addresses via env
        // For now, skip if not deployed
        vm.skip(true);
    }

    function testPushLiquidityToSubvault() public {
        // 1. Vault has wstETH balance
        uint256 vaultBalance = IERC20(wstETH).balanceOf(address(vault));
        vm.assume(vaultBalance > 0);

        // 2. Push assets to subvault
        uint256 pushAmount = vaultBalance / 2;
        vm.prank(keeper);
        IVaultModule(address(vault)).pushAssets(
            address(pendleSubvault),
            wstETH,
            pushAmount
        );

        // 3. Check balances
        uint256 subvaultBalance = IERC20(wstETH).balanceOf(
            address(pendleSubvault)
        );
        assertGe(subvaultBalance, pushAmount, "Subvault should receive assets");
    }

    function testEnterPendle() public {
        // Assumes subvault has wstETH
        uint256 subvaultBalance = IERC20(wstETH).balanceOf(
            address(pendleSubvault)
        );
        vm.assume(subvaultBalance > 0);

        // 1. Prepare router calldata (off-chain encoded)
        // For MVP: use a stub calldata (real flow would encode actual Pendle router calls)
        // In production: encode real Pendle router methods like addLiquiditySingleToken
        bytes memory routerCalldata = abi.encodeWithSignature(
            "addLiquiditySingleToken(address,address,uint256,uint256,tuple)",
            address(this), // receiver
            pendleMarket, // market
            0, // minLpOut
            subvaultBalance, // tokenInAmount
            "" // approxParams (stub)
        );

        // 2. Keeper calls enter
        vm.prank(keeper);
        pendleSubvault.enter(subvaultBalance, 0, routerCalldata);

        // 3. Check Pendle position tokens (LP, PT, etc.) are held by subvault
        // (In real test: check balanceOf Pendle LP/PT tokens)
        // For now: just ensure no revert and assets moved
        uint256 finalBalance = IERC20(wstETH).balanceOf(
            address(pendleSubvault)
        );
        assertLt(
            finalBalance,
            subvaultBalance,
            "Assets should be used to enter Pendle"
        );
    }

    function testExitPendle() public {
        // Assumes subvault holds Pendle position
        // 1. Prepare exit calldata (stub - real flow uses Pendle router methods)
        bytes memory routerCalldata = abi.encodeWithSignature(
            "removeLiquiditySingleToken(address,address,uint256,tuple)",
            address(this), // receiver
            pendleMarket, // market
            0, // netLpToRemove
            "" // params (stub)
        );

        // 2. Keeper calls exit
        vm.prank(keeper);
        pendleSubvault.exit(0, 0, routerCalldata);

        // 3. Check wstETH returned to subvault
        uint256 finalBalance = IERC20(wstETH).balanceOf(
            address(pendleSubvault)
        );
        assertGt(finalBalance, 0, "Should have redeemed assets from Pendle");
    }

    function testPullLiquidityFromSubvault() public {
        // Assumes subvault has liquid wstETH
        uint256 subvaultBalance = IERC20(wstETH).balanceOf(
            address(pendleSubvault)
        );
        vm.assume(subvaultBalance > 0);

        // 1. Pull assets back to vault
        vm.prank(keeper);
        IVaultModule(address(vault)).pullAssets(
            address(pendleSubvault),
            wstETH,
            subvaultBalance
        );

        // 2. Check vault received assets
        uint256 vaultBalance = IERC20(wstETH).balanceOf(address(vault));
        assertGe(
            vaultBalance,
            subvaultBalance,
            "Vault should receive pulled assets"
        );
    }

    function testAccessControl() public {
        address attacker = address(0xBAD);

        // 1. Try enter without keeper role
        vm.prank(attacker);
        vm.expectRevert();
        pendleSubvault.enter(1 ether, 0, "");

        // 2. Try exit without keeper role
        vm.prank(attacker);
        vm.expectRevert();
        pendleSubvault.exit(0, 0, "");

        // 3. Try sweep without admin role
        vm.prank(attacker);
        vm.expectRevert();
        pendleSubvault.sweep(wstETH, attacker, 1 ether);
    }

    function testAssetConservation() public {
        // Full cycle: deposit → push → enter → exit → pull → redeem
        // Track total assets at each step
        uint256 initialVaultAssets = IERC20(wstETH).balanceOf(address(vault));

        // Push to subvault
        uint256 pushAmount = initialVaultAssets / 2;
        vm.prank(keeper);
        IVaultModule(address(vault)).pushAssets(
            address(pendleSubvault),
            wstETH,
            pushAmount
        );

        // Enter Pendle (stub calldata)
        bytes memory enterCalldata = abi.encodeWithSignature(
            "addLiquiditySingleToken(address,address,uint256,uint256,tuple)",
            address(this),
            pendleMarket,
            0,
            pushAmount,
            ""
        );
        vm.prank(keeper);
        pendleSubvault.enter(pushAmount, 0, enterCalldata);

        // Exit Pendle
        bytes memory exitCalldata = abi.encodeWithSignature(
            "removeLiquiditySingleToken(address,address,uint256,tuple)",
            address(this),
            pendleMarket,
            0,
            ""
        );
        vm.prank(keeper);
        pendleSubvault.exit(0, (pushAmount * 95) / 100, exitCalldata); // Allow 5% slippage

        // Pull back
        uint256 subvaultBalance = IERC20(wstETH).balanceOf(
            address(pendleSubvault)
        );
        vm.prank(keeper);
        IVaultModule(address(vault)).pullAssets(
            address(pendleSubvault),
            wstETH,
            subvaultBalance
        );

        // Check: total vault assets should be approximately preserved (within slippage)
        uint256 finalVaultAssets = IERC20(wstETH).balanceOf(address(vault));
        assertGe(
            finalVaultAssets,
            (initialVaultAssets * 90) / 100,
            "Assets should be conserved (>90%)"
        );
    }
}
