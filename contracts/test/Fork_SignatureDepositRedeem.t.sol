// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import {Vault} from "mellow/vaults/Vault.sol";
import {IShareManager} from "mellow/interfaces/managers/IShareManager.sol";
import {IConsensus} from "mellow/interfaces/permissions/IConsensus.sol";
import {SignatureDepositQueue} from "mellow/queues/SignatureDepositQueue.sol";
import {SignatureRedeemQueue} from "mellow/queues/SignatureRedeemQueue.sol";
import {ISignatureQueue} from "mellow/interfaces/queues/ISignatureQueue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Fork_SignatureDepositRedeem
 * @notice Fork tests for signature-based deposit and redeem flows (no oracle required)
 */
contract Fork_SignatureDepositRedeem is Test {
    Vault public vault;
    address public wstETH;
    address public deployer;
    address public user;
    uint256 public userPrivateKey;

    SignatureDepositQueue public depositQueue;
    SignatureRedeemQueue public redeemQueue;
    IConsensus public consensus;

    function setUp() public {
        // Load env vars (expects ARBITRUM_RPC_URL, WSTETH, etc.)
        string memory rpc = vm.envOr(
            "ARBITRUM_RPC_URL",
            string("https://arb1.arbitrum.io/rpc")
        );
        vm.createSelectFork(rpc);

        deployer = address(this);
        userPrivateKey = 0xA11CE;
        user = vm.addr(userPrivateKey);

        // Deploy system using DeploySystem script (mock for now; in real flow run the script first)
        // For this test we assume the vault is deployed and we know the addresses
        // In practice: run `forge script DeploySystem` then pass vault address via env
        vm.skip(true); // Skip until addresses are set
    }

    function testDepositAndMint() public {
        // 1. User approves wstETH to deposit queue
        uint256 depositAmount = 1 ether;
        deal(wstETH, user, depositAmount);
        vm.prank(user);
        IERC20(wstETH).approve(address(depositQueue), depositAmount);

        // 2. Build & sign order
        uint256 nonce = depositQueue.nonces(user);
        ISignatureQueue.Order memory order = ISignatureQueue.Order({
            orderId: 1,
            queue: address(depositQueue),
            asset: wstETH,
            caller: user,
            recipient: user,
            ordered: depositAmount,
            requested: depositAmount, // 1:1 for simplicity
            deadline: block.timestamp + 1 hours,
            nonce: nonce
        });

        bytes32 orderHash = depositQueue.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        IConsensus.Signature[] memory signatures = new IConsensus.Signature[](
            1
        );
        signatures[0] = IConsensus.Signature({
            signer: deployer,
            signature: signature
        });

        // 3. Execute deposit (anyone can call if signatures valid)
        vm.prank(user);
        depositQueue.deposit(order, signatures);

        // 4. Check shares minted
        IShareManager sm = vault.shareManager();
        uint256 shares = sm.activeSharesOf(user);
        assertGt(shares, 0, "Shares should be minted");
        assertEq(shares, depositAmount, "Shares should equal deposit 1:1");
    }

    function testRedeemAndBurn() public {
        // Assumes user has shares from previous deposit
        // 1. User requests redemption
        IShareManager sm = vault.shareManager();
        uint256 userShares = sm.activeSharesOf(user);
        vm.assume(userShares > 0);

        uint256 nonce = redeemQueue.nonces(user);
        ISignatureQueue.Order memory order = ISignatureQueue.Order({
            orderId: 2,
            queue: address(redeemQueue),
            asset: wstETH,
            caller: user,
            recipient: user,
            ordered: userShares,
            requested: userShares, // 1:1
            deadline: block.timestamp + 1 hours,
            nonce: nonce
        });

        bytes32 orderHash = redeemQueue.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        IConsensus.Signature[] memory signatures = new IConsensus.Signature[](
            1
        );
        signatures[0] = IConsensus.Signature({
            signer: deployer,
            signature: signature
        });

        // 2. Execute redeem
        vm.prank(user);
        redeemQueue.redeem(order, signatures);

        // 3. Check assets returned and shares burned
        uint256 finalShares = sm.activeSharesOf(user);
        assertEq(finalShares, 0, "All shares should be burned");
        uint256 finalAssets = IERC20(wstETH).balanceOf(user);
        assertGt(finalAssets, 0, "User should receive assets");
    }
}
