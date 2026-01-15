// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from 'forge-std/Test.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

import {Identity} from '@onchain-id/solidity/contracts/Identity.sol';
import {ImplementationAuthority as OnchainImplementationAuthority} from '@onchain-id/solidity/contracts/proxy/ImplementationAuthority.sol';
import {IdFactory} from '@onchain-id/solidity/contracts/factory/IdFactory.sol';
import {Gateway} from '@onchain-id/solidity/contracts/gateway/Gateway.sol';
import {ClaimIssuer} from '@onchain-id/solidity/contracts/ClaimIssuer.sol';

import {ClaimTopicsRegistry} from '@erc3643org/erc-3643/contracts/registry/implementation/ClaimTopicsRegistry.sol';
import {TrustedIssuersRegistry} from '@erc3643org/erc-3643/contracts/registry/implementation/TrustedIssuersRegistry.sol';
import {IdentityRegistryStorage} from '@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistryStorage.sol';
import {IdentityRegistry} from '@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistry.sol';
import {IdentityRegistryProxy} from '@erc3643org/erc-3643/contracts/proxy/IdentityRegistryProxy.sol';
import {IdentityRegistryStorageProxy} from '@erc3643org/erc-3643/contracts/proxy/IdentityRegistryStorageProxy.sol';
import {TrustedIssuersRegistryProxy} from '@erc3643org/erc-3643/contracts/proxy/TrustedIssuersRegistryProxy.sol';
import {ClaimTopicsRegistryProxy} from '@erc3643org/erc-3643/contracts/proxy/ClaimTopicsRegistryProxy.sol';
import {ModularComplianceProxy} from '@erc3643org/erc-3643/contracts/proxy/ModularComplianceProxy.sol';
import {ModularCompliance} from '@erc3643org/erc-3643/contracts/compliance/modular/ModularCompliance.sol';
import {Token} from '@erc3643org/erc-3643/contracts/token/Token.sol';
import {TREXImplementationAuthority} from '@erc3643org/erc-3643/contracts/proxy/authority/TREXImplementationAuthority.sol';
import {ITREXImplementationAuthority} from '@erc3643org/erc-3643/contracts/proxy/authority/ITREXImplementationAuthority.sol';
import {TREXFactory} from '@erc3643org/erc-3643/contracts/factory/TREXFactory.sol';

import {MaxSupplyModule} from 'contracts/compliance/modules/MaxSupplyModule.sol';
import {SalesManager} from 'contracts/SalesManager.sol';
import {TokenController} from 'contracts/TokenController.sol';
import {Factory} from 'contracts/Factory.sol';

import {IAccessManager} from 'contracts/interfaces/IAccessManager.sol';
import {IGovernance} from 'contracts/governance/IGovernance.sol';
import {Permission} from './Permissions.sol';

interface IUUPSUpgradeableLike {
    function upgradeTo(address newImplementation) external;

    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

// Shared structs need to be file-level so tests can import them directly.
struct Protocol {
    IAccessManager accessManager;
    IGovernance governance;
    SalesManager salesManager;
    TokenController tokenController;
    Factory factory;
    TREXFactory trexFactory;
    MaxSupplyModule maxSupplyModule;
    IdentityRegistry identityRegistry;
    IdentityRegistryStorage identityRegistryStorage;
    Gateway gateway;
    IdFactory idFactory;
    ClaimIssuer claimIssuer;
    ClaimTopicsRegistryProxy claimTopicsRegistry;
    TrustedIssuersRegistryProxy trustedIssuersRegistry;
    ModularComplianceProxy modularCompliance;
}

struct Accounts {
    address multisig;
    address identityRegistryAgent;
    address identityRegistryAgent2;
    address claimIssuer;
    address factoryShareDeployer;
    address salesManagerSalesConfig;
    address salesManagerSalesOperator;
    address salesManagerFundsAdmin;
    address fiatOrderSigner;
    address buyer;
    address tokenAgent;
    address user1;
    address user2;
}

abstract contract ProtocolFixture is Test {
    address internal constant ZERO = address(0);
    uint32 internal constant ONE_DAY = 1 days;
    uint32 internal constant TWO_DAYS = 2 days;
    uint32 internal constant THREE_DAYS = 3 days;

    // NOTE: JSON-based role/delay configuration is now resolved outside Solidity.
    // Solidity tests consume only strongly-typed data (Permission structs, role IDs, selectors).

    function defaultAccounts() internal pure returns (Accounts memory a) {
        a.multisig = vm.addr(2);
        a.identityRegistryAgent = vm.addr(3);
        a.identityRegistryAgent2 = vm.addr(4);
        a.claimIssuer = vm.addr(5);
        a.factoryShareDeployer = vm.addr(6);
        a.salesManagerSalesConfig = vm.addr(7);
        a.salesManagerSalesOperator = vm.addr(8);
        a.salesManagerFundsAdmin = vm.addr(9);
        a.fiatOrderSigner = vm.addr(10);
        a.buyer = vm.addr(11);
        a.tokenAgent = vm.addr(14);
        a.user1 = vm.addr(12);
        a.user2 = vm.addr(13);
    }

    function deployProtocol(Accounts memory a) internal returns (Protocol memory) {
        // OnchainID stack
        Identity idImplementation = new Identity(address(this), true);
        OnchainImplementationAuthority identityIa = new OnchainImplementationAuthority(address(idImplementation));
        IdFactory idFactory = new IdFactory(address(identityIa));
        Gateway gateway = new Gateway(address(idFactory), new address[](0));

        // TREX implementations and authority
        ClaimTopicsRegistry ctrImpl = new ClaimTopicsRegistry();
        TrustedIssuersRegistry tirImpl = new TrustedIssuersRegistry();
        IdentityRegistryStorage irsImpl = new IdentityRegistryStorage();
        IdentityRegistry irImpl = new IdentityRegistry();
        ModularCompliance mcImpl = new ModularCompliance();
        Token tokenImpl = new Token();
        TREXImplementationAuthority trexIa = new TREXImplementationAuthority(true, address(0), address(0));

        ITREXImplementationAuthority.Version memory version = ITREXImplementationAuthority.Version({
            major: 4,
            minor: 0,
            patch: 0
        });
        ITREXImplementationAuthority.TREXContracts memory trexContracts = ITREXImplementationAuthority.TREXContracts({
            tokenImplementation: address(tokenImpl),
            ctrImplementation: address(ctrImpl),
            irImplementation: address(irImpl),
            irsImplementation: address(irsImpl),
            tirImplementation: address(tirImpl),
            mcImplementation: address(mcImpl)
        });
        trexIa.addAndUseTREXVersion(version, trexContracts);

        TREXFactory trexFactory = new TREXFactory(address(trexIa), address(idFactory));
        idFactory.addTokenFactory(address(trexFactory));

        // Governance stack (real OZ AccessManager + Governance)
        address accessManager = _deployAccessManager(a.multisig);
        address governance = _deployGovernance(accessManager);

        // SalesManager proxy
        SalesManager salesManagerImpl = new SalesManager();
        SalesManager salesManager = SalesManager(address(new ERC1967Proxy(address(salesManagerImpl), '')));
        salesManager.initialize(address(governance));

        // TokenController proxy
        TokenController tokenControllerImpl = new TokenController();
        TokenController tokenController = TokenController(address(new ERC1967Proxy(address(tokenControllerImpl), '')));
        tokenController.initialize(address(governance));

        // MaxSupply module
        MaxSupplyModule maxSupplyModule = new MaxSupplyModule();

        // Factory proxy
        Factory factoryImpl = new Factory();
        Factory factory = Factory(payable(address(new ERC1967Proxy(address(factoryImpl), ''))));
        factory.initialize(
            address(trexFactory),
            address(salesManager),
            address(tokenController),
            address(maxSupplyModule),
            address(governance)
        );
        trexFactory.transferOwnership(address(factory));

        // Common registries proxies bound to TREX IA
        ClaimTopicsRegistryProxy claimTopicsRegistry = new ClaimTopicsRegistryProxy(address(trexIa));
        TrustedIssuersRegistryProxy trustedIssuersRegistry = new TrustedIssuersRegistryProxy(address(trexIa));
        IdentityRegistryStorageProxy irsProxy = new IdentityRegistryStorageProxy(address(trexIa));
        ModularComplianceProxy modularCompliance = new ModularComplianceProxy(address(trexIa));
        IdentityRegistryProxy irProxy = new IdentityRegistryProxy(
            address(trexIa),
            address(trustedIssuersRegistry),
            address(claimTopicsRegistry),
            address(irsProxy)
        );

        // Bind IRS to IR and transfer ownership to TREXFactory
        IdentityRegistryStorage(address(irsProxy)).bindIdentityRegistry(address(irProxy));
        IdentityRegistryStorage(address(irsProxy)).transferOwnership(address(trexFactory));
        idFactory.transferOwnership(address(gateway));

        // Claim/issuer registries owned by TREXFactory for governance operations
        ClaimTopicsRegistry(address(claimTopicsRegistry)).transferOwnership(address(trexFactory));
        TrustedIssuersRegistry(address(trustedIssuersRegistry)).transferOwnership(address(trexFactory));

        // Hand IR ownership to multisig so agents can be managed
        IdentityRegistry(address(irProxy)).transferOwnership(a.multisig);

        ClaimIssuer claimIssuerContract = new ClaimIssuer(a.claimIssuer);

        Protocol memory result;
        result.accessManager = IAccessManager(accessManager);
        result.governance = IGovernance(governance);
        result.salesManager = salesManager;
        result.tokenController = tokenController;
        result.factory = factory;
        result.trexFactory = trexFactory;
        result.maxSupplyModule = maxSupplyModule;
        result.identityRegistry = IdentityRegistry(address(irProxy));
        result.identityRegistryStorage = IdentityRegistryStorage(address(irsProxy));
        result.gateway = gateway;
        result.idFactory = idFactory;
        result.claimIssuer = claimIssuerContract;
        result.claimTopicsRegistry = claimTopicsRegistry;
        result.trustedIssuersRegistry = trustedIssuersRegistry;
        result.modularCompliance = modularCompliance;
        return result;
    }

    function defaultRoleSetup(Protocol memory p, Accounts memory a) internal {
        // Apply strongly-typed permissions
        Permission[] memory perms = _defaultPermissions(p);
        _applyPermissions(p, a.multisig, perms);

        // Grant roles (multisig is admin)
        _grantRole(p, a.multisig, p.governance.UPGRADER_ROLE(), a.multisig);
        _grantRole(p, a.multisig, p.governance.SHARE_DEPLOYER_ROLE(), a.factoryShareDeployer);
        _grantRole(p, a.multisig, p.governance.SALES_CONFIG_ROLE(), a.salesManagerSalesConfig);
        _grantRole(p, a.multisig, p.governance.SALES_OPERATOR_ROLE(), a.salesManagerSalesOperator);
        _grantRole(p, a.multisig, p.governance.FUNDS_ADMIN_ROLE(), a.salesManagerFundsAdmin);
        _grantRole(p, a.multisig, p.governance.FIAT_ORDER_ROLE(), a.fiatOrderSigner);
        _grantRole(p, a.multisig, p.governance.PAUSER_ROLE(), a.tokenAgent);
        _grantRole(p, a.multisig, p.governance.MINTER_ROLE(), a.tokenAgent);
        _grantRole(p, a.multisig, p.governance.BURNER_ROLE(), a.tokenAgent);
        _grantRole(p, a.multisig, p.governance.FREEZER_ROLE(), a.tokenAgent);
        _grantRole(p, a.multisig, p.governance.FORCE_ROLE(), a.tokenAgent);
        _grantRole(p, a.multisig, p.governance.RECOVERY_ROLE(), a.tokenAgent);
    }

    function addGlobalIrAgents(Protocol memory p, Accounts memory a) internal {
        vm.prank(a.multisig);
        p.identityRegistry.addAgent(a.identityRegistryAgent);
        vm.prank(a.multisig);
        p.identityRegistry.addAgent(a.identityRegistryAgent2);
    }

    function _setRoleForSelector(
        Protocol memory p,
        address admin,
        address target,
        bytes4 selector,
        uint64 roleId
    ) internal {
        vm.prank(admin);
        p.accessManager.setTargetFunctionRole(target, _toSingle(selector), roleId);
    }

    function _grantRole(Protocol memory p, address admin, uint64 roleId, address account) internal {
        vm.prank(admin);
        // Delay logic is ensured by OpenZeppelin's AccessManager
        // Tests need roles usable immediately; grant with zero delay even though delays are tracked from config.
        p.accessManager.grantRole(roleId, account, 0);
    }

    function _toSingle(bytes4 selector) internal pure returns (bytes4[] memory arr) {
        arr = new bytes4[](1);
        arr[0] = selector;
    }

    function _single(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _singleBytes(bytes memory data) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = data;
    }

    function _defaultPermissions(Protocol memory p) internal view returns (Permission[] memory perms) {
        // 5 (Factory) + 18 (SalesManager) + 11 (TokenController) = 34
        perms = new Permission[](34);

        uint64 adminRole = p.governance.ADMIN_ROLE();
        uint64 upgraderRole = p.governance.UPGRADER_ROLE();
        uint64 shareDeployerRole = p.governance.SHARE_DEPLOYER_ROLE();
        uint64 salesOperatorRole = p.governance.SALES_OPERATOR_ROLE();
        uint64 salesConfigRole = p.governance.SALES_CONFIG_ROLE();
        uint64 fundsAdminRole = p.governance.FUNDS_ADMIN_ROLE();
        uint64 fiatOrderRole = p.governance.FIAT_ORDER_ROLE();
        uint64 pauserRole = p.governance.PAUSER_ROLE();
        uint64 minterRole = p.governance.MINTER_ROLE();
        uint64 burnerRole = p.governance.BURNER_ROLE();
        uint64 freezerRole = p.governance.FREEZER_ROLE();
        uint64 forceRole = p.governance.FORCE_ROLE();
        uint64 recoveryRole = p.governance.RECOVERY_ROLE();

        uint256 i;

        // Factory (upgrade selectors live on the UUPS proxy)
        perms[i++] = Permission({
            target: address(p.factory),
            selector: IUUPSUpgradeableLike.upgradeTo.selector,
            roleId: upgraderRole
        });
        perms[i++] = Permission({
            target: address(p.factory),
            selector: IUUPSUpgradeableLike.upgradeToAndCall.selector,
            roleId: upgraderRole
        });
        perms[i++] = Permission({
            target: address(p.factory),
            selector: Factory.editMaxSupplyModule.selector,
            roleId: adminRole
        });
        perms[i++] = Permission({
            target: address(p.factory),
            selector: Factory.deployShareSuite.selector,
            roleId: adminRole
        });
        perms[i++] = Permission({
            target: address(p.factory),
            selector: Factory.createShare.selector,
            roleId: shareDeployerRole
        });

        // SalesManager (upgrade selectors live on the UUPS proxy)
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: IUUPSUpgradeableLike.upgradeTo.selector,
            roleId: upgraderRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: IUUPSUpgradeableLike.upgradeToAndCall.selector,
            roleId: upgraderRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.rescueTokens.selector,
            roleId: fundsAdminRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.withdrawFunds.selector,
            roleId: fundsAdminRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.updateSaleFundsRecipient.selector,
            roleId: fundsAdminRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.setAllowedPaymentToken.selector,
            roleId: salesConfigRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.setPaymentTokenOracle.selector,
            roleId: salesConfigRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.setMaxOracleDelaySeconds.selector,
            roleId: salesConfigRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.setEmergencyPause.selector,
            roleId: salesOperatorRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.unsetEmergencyPause.selector,
            roleId: salesOperatorRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.createSale.selector,
            roleId: salesOperatorRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.cancelSale.selector,
            roleId: salesOperatorRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.pauseSale.selector,
            roleId: salesOperatorRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.unpauseSale.selector,
            roleId: salesOperatorRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.updateSalePriceUsdPerShare.selector,
            roleId: salesOperatorRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.updateSaleDeadline.selector,
            roleId: salesOperatorRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.updateSalePaymentTokensAllowed.selector,
            roleId: salesOperatorRole
        });
        perms[i++] = Permission({
            target: address(p.salesManager),
            selector: SalesManager.fulfillFiatOrder.selector,
            roleId: fiatOrderRole
        });

        // TokenController (upgrade selectors live on the UUPS proxy)
        perms[i++] = Permission({
            target: address(p.tokenController),
            selector: IUUPSUpgradeableLike.upgradeTo.selector,
            roleId: upgraderRole
        });
        perms[i++] = Permission({
            target: address(p.tokenController),
            selector: IUUPSUpgradeableLike.upgradeToAndCall.selector,
            roleId: upgraderRole
        });
        perms[i++] = Permission({
            target: address(p.tokenController),
            selector: TokenController.setTokenCaps.selector,
            roleId: adminRole
        });
        perms[i++] = Permission({
            target: address(p.tokenController),
            selector: TokenController.setTokenCapsInitial.selector,
            roleId: shareDeployerRole
        });
        perms[i++] = Permission({
            target: address(p.tokenController),
            selector: TokenController.pause.selector,
            roleId: pauserRole
        });
        perms[i++] = Permission({
            target: address(p.tokenController),
            selector: TokenController.unpause.selector,
            roleId: pauserRole
        });
        perms[i++] = Permission({
            target: address(p.tokenController),
            selector: TokenController.recover.selector,
            roleId: recoveryRole
        });
        perms[i++] = Permission({
            target: address(p.tokenController),
            selector: TokenController.mint.selector,
            roleId: minterRole
        });
        perms[i++] = Permission({
            target: address(p.tokenController),
            selector: TokenController.burn.selector,
            roleId: burnerRole
        });
        perms[i++] = Permission({
            target: address(p.tokenController),
            selector: TokenController.forceTransfer.selector,
            roleId: forceRole
        });
        perms[i++] = Permission({
            target: address(p.tokenController),
            selector: TokenController.setFrozen.selector,
            roleId: freezerRole
        });
    }

    function _applyPermissions(Protocol memory p, address admin, Permission[] memory perms) internal {
        for (uint256 i; i < perms.length; ++i) {
            _setRoleForSelector(p, admin, perms[i].target, perms[i].selector, perms[i].roleId);
        }
    }

    function _deployAccessManager(address admin) internal returns (address deployed) {
        bytes memory creation = vm.getCode(
            'openzeppelin-contracts-v5/contracts/access/manager/AccessManager.sol:AccessManager'
        );
        bytes memory bytecode = abi.encodePacked(creation, abi.encode(admin));
        assembly ('memory-safe') {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), 'AccessManager deploy failed');
    }

    function _deployGovernance(address accessManager) internal returns (address deployed) {
        bytes memory creation = vm.getCode('contracts/governance/Governance.sol:Governance');
        bytes memory bytecode = abi.encodePacked(creation, abi.encode(accessManager));
        assembly ('memory-safe') {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), 'Governance deploy failed');
    }
}
