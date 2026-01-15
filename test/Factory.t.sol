// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test, console2} from 'forge-std/Test.sol';
import {ProtocolFixture, Protocol, Accounts} from './fixtures/ProtocolFixture.sol';
import {IIdentity} from '@onchain-id/solidity/contracts/interface/IIdentity.sol';
import {IModularCompliance} from '@erc3643org/erc-3643/contracts/compliance/modular/IModularCompliance.sol';
import {Token} from '@erc3643org/erc-3643/contracts/token/Token.sol';
import {Identity} from '@onchain-id/solidity/contracts/Identity.sol';
import {IdentityRegistry} from '@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistry.sol';
import {IdentityRegistryStorageProxy} from '@erc3643org/erc-3643/contracts/proxy/IdentityRegistryStorageProxy.sol';
import {IdentityRegistryStorage} from '@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistryStorage.sol';
import {Factory} from 'contracts/Factory.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {ITREXFactory} from '@erc3643org/erc-3643/contracts/factory/ITREXFactory.sol';
import {MaxSupplyModule} from 'contracts/compliance/modules/MaxSupplyModule.sol';

contract FactoryTest is Test, ProtocolFixture {
    address internal deployer = vm.addr(1);
    Accounts internal acc = defaultAccounts();
    address internal multisig;
    address internal identityRegistryAgent;
    address internal identityRegistryAgent2;
    address internal claimIssuer;
    address internal factoryShareDeployer;
    address internal salesManagerSalesConfig;
    address internal salesManagerSalesOperator;
    address internal salesManagerFundsAdmin;
    address internal fiatOrderSigner;
    address internal buyer;
    address internal tokenAgent;
    address internal user1;
    address internal user2;
    uint256 constant DEFAULT_MAX_SUPPLY = 1000;
    Protocol internal p;

    function setUp() public {
        console2.log('Deploying protocol...');
        p = deployProtocol(acc);
        console2.log('Protocol deployed');
        defaultRoleSetup(p, acc);
        console2.log('Default role setup');
        addGlobalIrAgents(p, acc);
        console2.log('Global IR agents added');
        multisig = acc.multisig;
        identityRegistryAgent = acc.identityRegistryAgent;
        identityRegistryAgent2 = acc.identityRegistryAgent2;
        claimIssuer = acc.claimIssuer;
        factoryShareDeployer = acc.factoryShareDeployer;
        salesManagerSalesConfig = acc.salesManagerSalesConfig;
        salesManagerSalesOperator = acc.salesManagerSalesOperator;
        salesManagerFundsAdmin = acc.salesManagerFundsAdmin;
        fiatOrderSigner = acc.fiatOrderSigner;
        buyer = acc.buyer;
        tokenAgent = acc.tokenAgent;
        user1 = acc.user1;
        user2 = acc.user2;
    }

    function _configureAccessManager() internal {
        // Factory permissions
        vm.prank(multisig);
        _setRoleForSelector(address(p.factory), 'upgradeTo(address)', 1);
        vm.prank(multisig);
        _setRoleForSelector(address(p.factory), 'upgradeToAndCall(address,bytes)', 1);
        vm.prank(multisig);
        _setRoleForSelector(address(p.factory), 'editMaxSupplyModule(address)', 0);
        vm.prank(multisig);
        _setRoleForSelector(
            address(p.factory),
            'deployShareSuite(string,(address,string,string,uint8,address,address,address[],address[],address[],bytes[],bytes[]),(uint256[],address[],uint256[][]))',
            0
        );
        vm.prank(multisig);
        _setRoleForSelector(
            address(p.factory),
            'createShare(string,string,uint8,address,address[],address[],address,uint256[],address[],uint256[][],uint256)',
            2
        );

        // TokenController permissions
        vm.prank(multisig);
        _setRoleForSelector(address(p.tokenController), 'upgradeTo(address)', 1);
        vm.prank(multisig);
        _setRoleForSelector(address(p.tokenController), 'upgradeToAndCall(address,bytes)', 1);
        vm.prank(multisig);
        _setRoleForSelector(address(p.tokenController), 'setTokenCaps(address,uint256)', 0);
        vm.prank(multisig);
        _setRoleForSelector(address(p.tokenController), 'setTokenCapsInitial(address,uint256)', 2);
        vm.prank(multisig);
        _setRoleForSelector(address(p.tokenController), 'pause(address)', 7);
        vm.prank(multisig);
        _setRoleForSelector(address(p.tokenController), 'unpause(address)', 7);
        vm.prank(multisig);
        _setRoleForSelector(address(p.tokenController), 'mint(address,address,uint256)', 8);
        vm.prank(multisig);
        _setRoleForSelector(address(p.tokenController), 'burn(address,address,uint256)', 10);
        vm.prank(multisig);
        _setRoleForSelector(address(p.tokenController), 'forceTransfer(address,address,address,uint256)', 12);
        vm.prank(multisig);
        _setRoleForSelector(address(p.tokenController), 'setFrozen(address,address,bool)', 11);
        vm.prank(multisig);
        _setRoleForSelector(address(p.tokenController), 'recover(address,address,address,address)', 13);

        // SalesManager permissions (minimal for these tests)
        vm.prank(multisig);
        _setRoleForSelector(address(p.salesManager), 'upgradeTo(address)', 1);
        vm.prank(multisig);
        _setRoleForSelector(address(p.salesManager), 'upgradeToAndCall(address,bytes)', 1);

        // Grant roles
        vm.prank(multisig);
        _grantRole(0, multisig); // ADMIN_ROLE
        vm.prank(multisig);
        _grantRole(1, multisig); // UPGRADER_ROLE
        vm.prank(multisig);
        _grantRole(2, factoryShareDeployer); // SHARE_DEPLOYER_ROLE
        vm.prank(multisig);
        _grantRole(7, tokenAgent); // PAUSER_ROLE
        vm.prank(multisig);
        _grantRole(8, tokenAgent); // MINTER_ROLE
        vm.prank(multisig);
        _grantRole(10, tokenAgent); // BURNER_ROLE
        vm.prank(multisig);
        _grantRole(11, tokenAgent); // FREEZER_ROLE
        vm.prank(multisig);
        _grantRole(12, tokenAgent); // FORCE_ROLE
        vm.prank(multisig);
        _grantRole(13, tokenAgent); // RECOVERY_ROLE
    }

    function _addGlobalIrAgents() internal {
        vm.prank(multisig);
        IdentityRegistry(address(p.identityRegistry)).addAgent(identityRegistryAgent);
        vm.prank(multisig);
        IdentityRegistry(address(p.identityRegistry)).addAgent(identityRegistryAgent2);
    }

    function _setRoleForSelector(address target, string memory signature, uint64 roleId) internal {
        bytes4 selector = bytes4(keccak256(bytes(signature)));
        p.accessManager.setTargetFunctionRole(target, _toSingle(selector), roleId);
    }

    function _grantRole(uint64 roleId, address account) internal {
        p.accessManager.grantRole(roleId, account, 0);
    }

    // --- Tests (partial subset) ---

    function test_TrexFactoryOwnershipTransferred() public view {
        assertEq(p.trexFactory.owner(), address(p.factory));
        assertTrue(p.factory.isContractTrexFactoryOwner());
    }

    function test_CreateShareIndexesMappings() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        address tokenAddr = p.factory.createShare(
            'ACME',
            'ACM',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );

        uint256 lastId = p.factory.shareIdIndex();
        assertEq(p.factory.idToShare(lastId), tokenAddr);
        assertEq(p.factory.shareToId(tokenAddr), lastId);
    }

    function test_CreateShare_UniqueNameSymbol() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        p.factory.createShare(
            'Share1',
            'SHR1',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );

        vm.prank(factoryShareDeployer);
        p.factory.createShare(
            'Share2',
            'SHR2',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );

        assertEq(p.factory.shareIdIndex(), 2);
    }

    function test_CreateShare_DuplicateNameDifferentSymbol() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        p.factory.createShare(
            'Total',
            'TOT',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );

        vm.prank(factoryShareDeployer);
        p.factory.createShare(
            'Total',
            'TOTA',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );

        assertEq(p.factory.shareIdIndex(), 2);
    }

    function test_CreateShare_RejectDuplicateSymbol() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        p.factory.createShare(
            'Total',
            'TOT',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );

        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes('Factory_SymbolAlreadyUsed'));
        p.factory.createShare(
            'Totality',
            'TOT',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );
    }

    function test_EditMaxSupplyModule() public {
        MaxSupplyModule module = new MaxSupplyModule();
        vm.prank(multisig);
        p.factory.editMaxSupplyModule(address(module));
        assertEq(p.factory.maxSupplyModule(), address(module));
    }

    function test_IRSOwnershipCheck() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        // good IRS transferred to TREXFactory
        IdentityRegistryStorageProxy goodIrsProxy = new IdentityRegistryStorageProxy(
            address(p.trexFactory.getImplementationAuthority())
        );
        IdentityRegistryStorage(address(goodIrsProxy)).transferOwnership(address(p.trexFactory));

        vm.prank(factoryShareDeployer);
        p.factory.createShare(
            'WITHIRS',
            'WIR',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(goodIrsProxy),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );

        // bad IRS not transferred
        IdentityRegistryStorageProxy badIrsProxy = new IdentityRegistryStorageProxy(
            address(p.trexFactory.getImplementationAuthority())
        );
        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes('Factory_IRSNot0OrOwnedByTREXFactory'));
        p.factory.createShare(
            'WITHIRS2',
            'WIR2',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(badIrsProxy),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );
    }

    function test_Max4TokenAgents() public {
        address[] memory tokenAgents = new address[](1);
        tokenAgents[0] = user1;
        address[] memory irAgents = new address[](0);
        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes('Factory_CustomTokenAgentsNotAllowed'));
        p.factory.createShare(
            'N',
            'S',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );
    }

    function test_SalesManagerNotInTokenAgents() public {
        address[] memory tokenAgents = new address[](1);
        tokenAgents[0] = address(p.salesManager);
        address[] memory irAgents = new address[](1);
        irAgents[0] = identityRegistryAgent;

        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes('Factory_CustomTokenAgentsNotAllowed'));
        p.factory.createShare(
            'SM',
            'SM',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );
    }

    function test_MaxSupplyRequired() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes('Factory_MaxSupplyRequired'));
        p.factory.createShare(
            'ZERO',
            'ZERO',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            0
        );
    }

    function test_ShareIdIndexIncrements() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        uint256 beforeIndex = p.factory.shareIdIndex();

        vm.prank(factoryShareDeployer);
        p.factory.createShare(
            'X',
            'X',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );
        vm.prank(factoryShareDeployer);
        p.factory.createShare(
            'Y',
            'Y',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );

        assertEq(p.factory.shareIdIndex(), beforeIndex + 2);
    }

    function test_CreateShare_NotAuthorized() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        address attacker = vm.addr(99);
        vm.prank(attacker);
        vm.expectRevert(bytes('Factory_NotAuthorized'));
        p.factory.createShare(
            'ROLE',
            'ROL',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );
    }

    function test_ClaimIssuerConstraints() public {
        (address[] memory tokenAgents, ) = _defaultAgents();
        uint256[] memory sixClaims = new uint256[](6);
        address[] memory issuers = new address[](6);
        uint256[][] memory issuerClaims = new uint256[][](0);

        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes('Factory_Max5ClaimTopics'));
        p.factory.createShare(
            'C',
            'I',
            0,
            multisig,
            tokenAgents,
            tokenAgents,
            address(p.identityRegistryStorage),
            sixClaims,
            new address[](0),
            issuerClaims,
            DEFAULT_MAX_SUPPLY
        );

        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes('Factory_Max5Issuers'));
        p.factory.createShare(
            'C2',
            'I2',
            0,
            multisig,
            tokenAgents,
            tokenAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            issuers,
            issuerClaims,
            DEFAULT_MAX_SUPPLY
        );

        address[] memory oneIssuer = new address[](1);
        oneIssuer[0] = claimIssuer;
        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes('Factory_ClaimIssuerLengthMismatch'));
        p.factory.createShare(
            'C3',
            'I3',
            0,
            multisig,
            tokenAgents,
            tokenAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            oneIssuer,
            issuerClaims,
            DEFAULT_MAX_SUPPLY
        );
    }

    function test_RogueFactoryCannotCreateShare() public {
        // deploy rogue factory proxy without owning TREXFactory
        Factory factoryImpl = new Factory();
        Factory rogue = Factory(payable(address(new ERC1967Proxy(address(factoryImpl), ''))));
        rogue.initialize(
            address(p.trexFactory),
            address(p.salesManager),
            address(p.tokenController),
            address(p.maxSupplyModule),
            address(p.governance)
        );

        // allow createShare selector on rogue so it passes governance check
        vm.prank(multisig);
        _setRoleForSelector(
            address(rogue),
            'createShare(string,string,uint8,address,address[],address[],address,uint256[],address[],uint256[][],uint256)',
            2
        );
        address attacker = vm.addr(77);
        vm.prank(multisig);
        p.accessManager.grantRole(2, attacker, 0);

        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        vm.prank(attacker);
        vm.expectRevert(bytes('Factory_NotOwnerOfTREXFactory'));
        rogue.createShare(
            'R',
            'R',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );
    }

    function test_MaxSupplyEnforced() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        vm.prank(factoryShareDeployer);
        p.factory.createShare(
            'CAP',
            'CAP',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            1000
        );

        address tokenAddr = p.factory.idToShare(p.factory.shareIdIndex());
        Token token = Token(tokenAddr);
        address irAddr = address(token.identityRegistry());

        // register identity
        IIdentity buyerIdentity = IIdentity(address(new Identity(buyer, false)));
        vm.prank(identityRegistryAgent);
        IdentityRegistry(irAddr).registerIdentity(buyer, buyerIdentity, 1);

        // set capabilities and roles already granted
        uint256 caps = (1 << 1) | (1 << 2) | (1 << 3); // pause + mint + burn bits
        vm.prank(factoryShareDeployer);
        p.tokenController.setTokenCapsInitial(tokenAddr, caps);

        vm.prank(tokenAgent);
        p.tokenController.unpause(tokenAddr);

        vm.prank(tokenAgent);
        p.tokenController.mint(tokenAddr, buyer, 600);

        vm.prank(tokenAgent);
        vm.expectRevert(); // exceeds cap
        p.tokenController.mint(tokenAddr, buyer, 500);

        vm.prank(tokenAgent);
        p.tokenController.burn(tokenAddr, buyer, 200);
        vm.prank(tokenAgent);
        p.tokenController.mint(tokenAddr, buyer, 200);
    }

    function test_MaxSupplyModuleUpdateViaCompliance() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        vm.prank(factoryShareDeployer);
        p.factory.createShare(
            'MSU',
            'MSU',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            1000
        );

        address tokenAddr = p.factory.idToShare(p.factory.shareIdIndex());
        Token token = Token(tokenAddr);
        address mcAddr = address(token.compliance());
        IModularCompliance mc = IModularCompliance(mcAddr);
        MaxSupplyModule module = MaxSupplyModule(p.maxSupplyModule);

        // initial max supply should be 1000
        assertEq(module.getMaxSupply(mcAddr), 1000);

        bytes memory setCall = abi.encodeWithSignature('setMaxSupply(uint256)', 2000);
        vm.prank(multisig);
        mc.callModuleFunction(setCall, address(module));
        assertEq(module.getMaxSupply(mcAddr), 2000);

        bytes memory setZero = abi.encodeWithSignature('setMaxSupply(uint256)', 0);
        vm.prank(multisig);
        mc.callModuleFunction(setZero, address(module));
        assertEq(module.getMaxSupply(mcAddr), 0);
    }

    function test_UpgradeRequiresRole() public {
        address attacker = vm.addr(77);
        Factory factoryImpl = new Factory();
        vm.prank(attacker);
        vm.expectRevert(bytes('Factory_NotAuthorized'));
        p.factory.upgradeTo(address(factoryImpl));
    }

    function test_UpgradeWithRolePreservesState() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        uint256 beforeIndex = p.factory.shareIdIndex();

        vm.prank(factoryShareDeployer);
        p.factory.createShare(
            'UP',
            'UP',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );

        MaxSupplyModule newModule = new MaxSupplyModule();
        vm.prank(multisig);
        p.factory.editMaxSupplyModule(address(newModule));
        address beforeModule = p.factory.maxSupplyModule();

        Factory newImpl = new Factory();
        vm.prank(multisig);
        p.factory.upgradeTo(address(newImpl));

        assertEq(p.factory.shareIdIndex(), beforeIndex + 1);
        assertEq(p.factory.maxSupplyModule(), beforeModule);
        address tokenAddr = p.factory.idToShare(p.factory.shareIdIndex());
        assertEq(p.factory.shareToId(tokenAddr), p.factory.shareIdIndex());
    }

    function test_MaxSupplySetBelowCurrentReverts() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        vm.prank(factoryShareDeployer);
        p.factory.createShare(
            'MST',
            'MST',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            1000
        );

        address tokenAddr = p.factory.idToShare(p.factory.shareIdIndex());
        Token token = Token(tokenAddr);
        address mcAddr = address(token.compliance());
        IModularCompliance mc = IModularCompliance(mcAddr);
        MaxSupplyModule module = MaxSupplyModule(p.maxSupplyModule);

        // caps and unpause
        uint256 caps = (1 << 1) | (1 << 2) | (1 << 3); // pause + mint + burn
        vm.prank(factoryShareDeployer);
        p.tokenController.setTokenCapsInitial(tokenAddr, caps);
        vm.prank(tokenAgent);
        p.tokenController.unpause(tokenAddr);

        // register identity
        IIdentity buyerIdentity = IIdentity(address(new Identity(buyer, false)));
        vm.prank(identityRegistryAgent);
        p.identityRegistry.registerIdentity(buyer, buyerIdentity, 1);

        vm.prank(tokenAgent);
        p.tokenController.mint(tokenAddr, buyer, 600);
        assertEq(module.getCurrentSupply(mcAddr), 600);
        assertEq(module.getMaxSupply(mcAddr), 1000);

        vm.prank(tokenAgent);
        p.tokenController.burn(tokenAddr, buyer, 250);
        assertEq(module.getCurrentSupply(mcAddr), 350);

        // cannot lower below current supply
        bytes memory setTooLow = abi.encodeWithSignature('setMaxSupply(uint256)', 200);
        vm.prank(multisig);
        vm.expectRevert(bytes('MaxSupplyModule: new max supply cannot be below current supply'));
        mc.callModuleFunction(setTooLow, address(module));
    }

    function test_GlobalIrAgentRegistersIdentity() public {
        address irAddr = address(p.identityRegistry);
        IdentityRegistry ir = IdentityRegistry(irAddr);

        IIdentity buyerIdentity = IIdentity(address(new Identity(buyer, false)));
        vm.prank(identityRegistryAgent);
        ir.registerIdentity(buyer, buyerIdentity, 1);

        assertEq(address(ir.identity(buyer)), address(buyerIdentity));
        address[] memory linked = IdentityRegistryStorage(address(p.identityRegistryStorage))
            .linkedIdentityRegistries();
        bool found;
        for (uint256 i = 0; i < linked.length; i++) {
            if (linked[i] == irAddr) {
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function test_MaxSupplyCapBoundOnDeployment() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        vm.prank(factoryShareDeployer);
        p.factory.createShare(
            'POST',
            'POST',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            777
        );

        address tokenAddr = p.factory.idToShare(p.factory.shareIdIndex());
        Token token = Token(tokenAddr);
        address irAddr = address(token.identityRegistry());
        address mcAddr = address(token.compliance());

        // IRS bound to IR
        address irsAddr = address(IdentityRegistry(irAddr).identityStorage());
        address[] memory linked = IdentityRegistryStorage(irsAddr).linkedIdentityRegistries();
        bool found;
        for (uint256 i = 0; i < linked.length; i++) {
            if (linked[i] == irAddr) {
                found = true;
                break;
            }
        }
        assertTrue(found);

        // max supply module bound and cap set
        address[] memory modules = IModularCompliance(mcAddr).getModules();
        bool moduleFound;
        for (uint256 i = 0; i < modules.length; i++) {
            if (modules[i] == address(p.maxSupplyModule)) {
                moduleFound = true;
                break;
            }
        }
        assertTrue(moduleFound);
        assertEq(MaxSupplyModule(p.maxSupplyModule).getMaxSupply(mcAddr), 777);
    }

    function test_AdminGrantsAndRevokesShareDeployerRole() public {
        address attacker = vm.addr(55);
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        // attacker cannot create initially
        vm.prank(attacker);
        vm.expectRevert(bytes('Factory_NotAuthorized'));
        p.factory.createShare(
            'R1',
            'R1',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );

        // multisig (admin) grants role
        vm.prank(multisig);
        p.accessManager.grantRole(2, attacker, 0); // SHARE_DEPLOYER_ROLE

        // now succeeds
        vm.prank(attacker);
        p.factory.createShare(
            'R2',
            'R2',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );

        // revoke and ensure revert
        vm.prank(multisig);
        p.accessManager.revokeRole(2, attacker);
        vm.prank(attacker);
        vm.expectRevert(bytes('Factory_NotAuthorized'));
        p.factory.createShare(
            'R3',
            'R3',
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            DEFAULT_MAX_SUPPLY
        );
    }

    function test_SaltCollisionDeployShareSuite() public {
        ITREXFactory.TokenDetails memory td = ITREXFactory.TokenDetails({
            owner: multisig,
            name: 'A',
            symbol: 'A',
            decimals: 0,
            irs: address(p.identityRegistryStorage),
            ONCHAINID: ZERO,
            irAgents: _single(identityRegistryAgent),
            tokenAgents: _single(tokenAgent),
            complianceModules: _single(address(p.maxSupplyModule)),
            complianceSettings: _singleBytes(abi.encodeWithSignature('setMaxSupply(uint256)', DEFAULT_MAX_SUPPLY))
        });
        ITREXFactory.ClaimDetails memory cd = ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0),
            issuers: new address[](0),
            issuerClaims: new uint256[][](0)
        });

        vm.prank(multisig);
        p.factory.deployShareSuite('SALT', td, cd);
        vm.prank(multisig);
        vm.expectRevert(bytes('Factory_SaltAlreadyUsed'));
        td.name = 'B';
        td.symbol = 'B';
        p.factory.deployShareSuite('SALT', td, cd);
    }

    function test_UpgradePreservesTrexFactoryOwnership() public {
        assertEq(p.trexFactory.owner(), address(p.factory));
        Factory newImpl = new Factory();
        vm.prank(multisig);
        p.factory.upgradeTo(address(newImpl));
        assertEq(p.trexFactory.owner(), address(p.factory));
        assertTrue(p.factory.isContractTrexFactoryOwner());
    }

    // helpers

    // helpers
    function _defaultAgents() internal view returns (address[] memory tokenAgents, address[] memory irAgents) {
        tokenAgents = new address[](0);
        irAgents = new address[](1);
        irAgents[0] = identityRegistryAgent;
    }
}
