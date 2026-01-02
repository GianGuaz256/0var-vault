// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Factory} from "mellow/factories/Factory.sol";
import {VaultConfigurator} from "mellow/vaults/VaultConfigurator.sol";
import {Vault} from "mellow/vaults/Vault.sol";

import {BasicShareManager} from "mellow/managers/BasicShareManager.sol";
import {FeeManager} from "mellow/managers/FeeManager.sol";
import {RiskManager} from "mellow/managers/RiskManager.sol";
import {Oracle} from "mellow/oracles/Oracle.sol";
import {Verifier} from "mellow/permissions/Verifier.sol";
import {Consensus} from "mellow/permissions/Consensus.sol";
import {IConsensus} from "mellow/interfaces/permissions/IConsensus.sol";

import {SignatureDepositQueue} from "mellow/queues/SignatureDepositQueue.sol";
import {SignatureRedeemQueue} from "mellow/queues/SignatureRedeemQueue.sol";

import {IVerifier} from "mellow/interfaces/permissions/IVerifier.sol";
import {IOracle} from "mellow/interfaces/oracles/IOracle.sol";
import {IFactoryEntity} from "mellow/interfaces/factories/IFactoryEntity.sol";

import {PendleSubvault} from "contracts/src/subvaults/PendleSubvault.sol";
import {IPendleRouter} from "contracts/src/interfaces/IPendleRouter.sol";

/// @notice End-to-end deploy (fork-first) of a minimal Core Vault stack + PendleSubvault.
/// @dev This is MVP-focused and intentionally uses simple versions/params.
contract DeploySystem is Script {
    // Vault roles (computed as in flexible-vaults)
    bytes32 internal constant CREATE_QUEUE_ROLE =
        keccak256("modules.ShareModule.CREATE_QUEUE_ROLE");
    bytes32 internal constant CREATE_SUBVAULT_ROLE =
        keccak256("modules.VaultModule.CREATE_SUBVAULT_ROLE");
    bytes32 internal constant PUSH_LIQUIDITY_ROLE =
        keccak256("modules.VaultModule.PUSH_LIQUIDITY_ROLE");
    bytes32 internal constant PULL_LIQUIDITY_ROLE =
        keccak256("modules.VaultModule.PULL_LIQUIDITY_ROLE");

    // Oracle roles
    bytes32 internal constant ORACLE_SUBMIT_REPORTS_ROLE =
        keccak256("oracles.Oracle.SUBMIT_REPORTS_ROLE");
    bytes32 internal constant ORACLE_ACCEPT_REPORT_ROLE =
        keccak256("oracles.Oracle.ACCEPT_REPORT_ROLE");
    bytes32 internal constant ORACLE_SET_SECURITY_PARAMS_ROLE =
        keccak256("oracles.Oracle.SET_SECURITY_PARAMS_ROLE");

    // RiskManager roles
    bytes32 internal constant RM_ALLOW_SUBVAULT_ASSETS_ROLE =
        keccak256("managers.RiskManager.ALLOW_SUBVAULT_ASSETS_ROLE");
    bytes32 internal constant RM_SET_SUBVAULT_LIMIT_ROLE =
        keccak256("managers.RiskManager.SET_SUBVAULT_LIMIT_ROLE");

    // Verifier roles (checked on Vault)
    bytes32 internal constant VERIFIER_ALLOW_CALL_ROLE =
        keccak256("permissions.Verifier.ALLOW_CALL_ROLE");
    bytes32 internal constant VERIFIER_CALLER_ROLE =
        keccak256("permissions.Verifier.CALLER_ROLE");

    // PendleSubvault keeper role (checked on Vault)
    bytes32 internal constant PENDLE_KEEPER_ROLE =
        keccak256("mellowpendle.PendleSubvault.KEEPER_ROLE");

    function run() external {
        uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address deployer = pk == 0 ? msg.sender : vm.addr(pk);

        if (pk == 0) vm.startBroadcast();
        else vm.startBroadcast(pk);

        // ---- Deploy factories (as proxies) ----
        Factory shareManagerFactory = _deployFactoryProxy(
            "ShareManagerFactory",
            deployer
        );
        Factory feeManagerFactory = _deployFactoryProxy(
            "FeeManagerFactory",
            deployer
        );
        Factory riskManagerFactory = _deployFactoryProxy(
            "RiskManagerFactory",
            deployer
        );
        Factory oracleFactory = _deployFactoryProxy("OracleFactory", deployer);
        Factory vaultFactory = _deployFactoryProxy("VaultFactory", deployer);

        Factory consensusFactory = _deployFactoryProxy(
            "ConsensusFactory",
            deployer
        );
        Factory depositQueueFactory = _deployFactoryProxy(
            "DepositQueueFactory",
            deployer
        );
        Factory redeemQueueFactory = _deployFactoryProxy(
            "RedeemQueueFactory",
            deployer
        );
        Factory verifierFactory = _deployFactoryProxy(
            "VerifierFactory",
            deployer
        );
        Factory subvaultFactory = _deployFactoryProxy(
            "SubvaultFactory",
            deployer
        );

        // ---- Deploy and register implementations ----
        _registerImpl(
            shareManagerFactory,
            address(new BasicShareManager("BasicShareManager", 1))
        );
        _registerImpl(
            feeManagerFactory,
            address(new FeeManager("FeeManager", 1))
        );
        _registerImpl(
            riskManagerFactory,
            address(new RiskManager("RiskManager", 1))
        );
        _registerImpl(oracleFactory, address(new Oracle("Oracle", 1)));
        _registerImpl(verifierFactory, address(new Verifier("Verifier", 1)));
        _registerImpl(consensusFactory, address(new Consensus("Consensus", 1)));

        // Signature queues have immutables (consensusFactory)
        _registerImpl(
            depositQueueFactory,
            address(
                new SignatureDepositQueue(
                    "SignatureDepositQueue",
                    1,
                    address(consensusFactory)
                )
            )
        );
        _registerImpl(
            redeemQueueFactory,
            address(
                new SignatureRedeemQueue(
                    "SignatureRedeemQueue",
                    1,
                    address(consensusFactory)
                )
            )
        );

        // Vault has immutables (queue factories, subvault factory, verifier factory)
        _registerImpl(
            vaultFactory,
            address(
                new Vault(
                    "Vault",
                    1,
                    address(depositQueueFactory),
                    address(redeemQueueFactory),
                    address(subvaultFactory),
                    address(verifierFactory)
                )
            )
        );

        VaultConfigurator vaultConfigurator = new VaultConfigurator(
            address(shareManagerFactory),
            address(feeManagerFactory),
            address(riskManagerFactory),
            address(oracleFactory),
            address(vaultFactory)
        );

        // ---- Create vault stack ----
        address wstETH = vm.envAddress("WSTETH");

        Vault.RoleHolder[] memory holders = new Vault.RoleHolder[](11);
        holders[0] = Vault.RoleHolder({
            role: CREATE_QUEUE_ROLE,
            holder: deployer
        });
        holders[1] = Vault.RoleHolder({
            role: CREATE_SUBVAULT_ROLE,
            holder: deployer
        });
        holders[2] = Vault.RoleHolder({
            role: PUSH_LIQUIDITY_ROLE,
            holder: deployer
        });
        holders[3] = Vault.RoleHolder({
            role: PULL_LIQUIDITY_ROLE,
            holder: deployer
        });
        holders[4] = Vault.RoleHolder({
            role: ORACLE_SUBMIT_REPORTS_ROLE,
            holder: deployer
        });
        holders[5] = Vault.RoleHolder({
            role: ORACLE_ACCEPT_REPORT_ROLE,
            holder: deployer
        });
        holders[6] = Vault.RoleHolder({
            role: ORACLE_SET_SECURITY_PARAMS_ROLE,
            holder: deployer
        });
        holders[7] = Vault.RoleHolder({
            role: RM_ALLOW_SUBVAULT_ASSETS_ROLE,
            holder: deployer
        });
        holders[8] = Vault.RoleHolder({
            role: RM_SET_SUBVAULT_LIMIT_ROLE,
            holder: deployer
        });
        holders[9] = Vault.RoleHolder({
            role: VERIFIER_ALLOW_CALL_ROLE,
            holder: deployer
        });
        holders[10] = Vault.RoleHolder({
            role: PENDLE_KEEPER_ROLE,
            holder: deployer
        });

        // Share manager: BasicShareManager expects bytes32 merkleRoot
        bytes memory shareManagerParams = abi.encode(bytes32(0));
        // Fee manager: owner, feeRecipient, fees = 0
        uint24 zeroFee = 0;
        bytes memory feeManagerParams = abi.encode(
            deployer,
            deployer,
            zeroFee,
            zeroFee,
            zeroFee,
            zeroFee
        );
        // Risk manager: vault limit (int256)
        int256 vaultLimit = int256(type(int128).max);
        bytes memory riskManagerParams = abi.encode(vaultLimit);
        // Oracle: security params + supported assets (wstETH only)
        IOracle.SecurityParams memory sp = IOracle.SecurityParams({
            maxAbsoluteDeviation: type(uint224).max,
            suspiciousAbsoluteDeviation: type(uint224).max,
            maxRelativeDeviationD18: type(uint64).max,
            suspiciousRelativeDeviationD18: type(uint64).max,
            timeout: 1 seconds,
            depositInterval: 1 seconds,
            redeemInterval: 1 seconds
        });
        address[] memory supportedAssets = new address[](1);
        supportedAssets[0] = wstETH;
        bytes memory oracleParams = abi.encode(sp, supportedAssets);

        VaultConfigurator.InitParams memory initParams = VaultConfigurator
            .InitParams({
                version: 0,
                proxyAdmin: deployer,
                vaultAdmin: deployer,
                shareManagerVersion: 0,
                shareManagerParams: shareManagerParams,
                feeManagerVersion: 0,
                feeManagerParams: feeManagerParams,
                riskManagerVersion: 0,
                riskManagerParams: riskManagerParams,
                oracleVersion: 0,
                oracleParams: oracleParams,
                defaultDepositHook: address(0),
                defaultRedeemHook: address(0),
                queueLimit: 10,
                roleHolders: holders
            });

        (
            address shareManager,
            address feeManager,
            address riskManager,
            address oracle,
            address vaultAddr
        ) = vaultConfigurator.create(initParams);

        Vault vault = Vault(payable(vaultAddr));

        console2.log("shareManager", shareManager);
        console2.log("feeManager", feeManager);
        console2.log("riskManager", riskManager);
        console2.log("oracle", oracle);
        console2.log("vault", vaultAddr);

        // ---- Create Consensus (trusted signer set = deployer) ----
        address consensus = consensusFactory.create(
            0,
            deployer,
            abi.encode(deployer)
        );
        Consensus(consensus).addSigner(
            deployer,
            1,
            IConsensus.SignatureType.EIP712
        );
        console2.log("consensus", consensus);

        // ---- Create signature queues ----
        bytes memory queueData = abi.encode(
            consensus,
            "MellowPendleVault",
            "1"
        );
        vault.createQueue(0, true, deployer, wstETH, queueData); // deposit
        vault.createQueue(0, false, deployer, wstETH, queueData); // redeem

        // ---- Create Verifier for PendleSubvault ----
        address pendleVerifier = verifierFactory.create(
            0,
            deployer,
            abi.encode(vaultAddr, bytes32(0))
        );
        console2.log("pendleVerifier", pendleVerifier);

        // ---- Deploy PendleSubvault impl (immutables) + register + create proxy via vault ----
        address pendleRouter = vm.envAddress("PENDLE_ROUTER");
        address pendleMarket = vm.envAddress("PENDLE_MARKET");
        address pendleSy = vm.envAddress("PENDLE_SY");
        address pendlePt = vm.envAddress("PENDLE_PT");
        address pendleYt = vm.envAddress("PENDLE_YT");

        address pendleSubvaultImpl = address(
            new PendleSubvault(
                wstETH,
                pendleRouter,
                pendleMarket,
                pendleSy,
                pendlePt,
                pendleYt,
                vaultAddr
            )
        );
        _registerImpl(subvaultFactory, pendleSubvaultImpl);

        // Grant Verifier.CALLER_ROLE to the Subvault address AFTER it is created (done in ConfigureSystem).
        address pendleSubvault = vault.createSubvault(
            0,
            deployer,
            pendleVerifier
        );
        console2.log("pendleSubvault", pendleSubvault);

        vm.stopBroadcast();
    }

    function _deployFactoryProxy(
        string memory name,
        address proxyAdmin
    ) internal returns (Factory factory) {
        Factory impl = new Factory(name, 1);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            proxyAdmin,
            abi.encodeCall(IFactoryEntity.initialize, (abi.encode(proxyAdmin)))
        );
        return Factory(address(proxy));
    }

    function _registerImpl(Factory factory, address implementation) internal {
        factory.proposeImplementation(implementation);
        factory.acceptProposedImplementation(implementation);
    }
}
