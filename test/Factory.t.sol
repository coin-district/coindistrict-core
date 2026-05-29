// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {ProtocolFixture, Protocol, Accounts, RoleIds} from "./fixtures/ProtocolFixture.sol";
import {IIdentity} from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import {IModularCompliance} from "@erc3643org/erc-3643/contracts/compliance/modular/IModularCompliance.sol";
import {Token} from "@erc3643org/erc-3643/contracts/token/Token.sol";
import {Identity} from "@onchain-id/solidity/contracts/Identity.sol";
import {IdentityRegistry} from "@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistry.sol";
import {IdentityRegistryStorageProxy} from "@erc3643org/erc-3643/contracts/proxy/IdentityRegistryStorageProxy.sol";
import {
    IdentityRegistryStorage
} from "@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistryStorage.sol";
import {Factory} from "contracts/Factory.sol";
import {IFactory} from "contracts/IFactory.sol";
import {IClaimIssuer} from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import {ClaimTopicsRegistry} from "@erc3643org/erc-3643/contracts/registry/implementation/ClaimTopicsRegistry.sol";
import {
    TrustedIssuersRegistry
} from "@erc3643org/erc-3643/contracts/registry/implementation/TrustedIssuersRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ITREXFactory} from "@erc3643org/erc-3643/contracts/factory/ITREXFactory.sol";
import {MaxSupplyModule} from "contracts/compliance/modules/MaxSupplyModule.sol";

contract FactoryTest is Test, ProtocolFixture {
    event ShareCreated(
        uint256 indexed shareId, address indexed shareAddress, string shareName, string shareSymbol, uint8 shareDecimals
    );
    event EditMaxSupplyModule(address maxSupplyModule);

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
        p = deployProtocol(acc);
        defaultRoleSetup(p, acc);
        addGlobalIrAgents(p, acc);
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

    // Initialization

    function test_Factory_implementation_disables_initializers() public {
        Factory impl = new Factory();
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        impl.initialize(
            address(p.trexFactory),
            address(p.salesManager),
            address(p.tokenController),
            address(p.maxSupplyModule),
            address(p.governance)
        );
    }

    function test_Factory_initialize_rejects_zero_governance() public {
        Factory impl = new Factory();
        Factory proxy = Factory(payable(address(new ERC1967Proxy(address(impl), ""))));
        vm.expectRevert(IFactory.InvalidGovernanceAddress.selector);
        proxy.initialize(
            address(p.trexFactory),
            address(p.salesManager),
            address(p.tokenController),
            address(p.maxSupplyModule),
            ZERO
        );
    }

    function test_Factory_initialize_rejects_zero_trex_factory() public {
        Factory impl = new Factory();
        Factory proxy = Factory(payable(address(new ERC1967Proxy(address(impl), ""))));
        vm.expectRevert(IFactory.InvalidTREXFactoryAddress.selector);
        proxy.initialize(
            ZERO, address(p.salesManager), address(p.tokenController), address(p.maxSupplyModule), address(p.governance)
        );
    }

    function test_Factory_initialize_rejects_zero_sales_manager() public {
        Factory impl = new Factory();
        Factory proxy = Factory(payable(address(new ERC1967Proxy(address(impl), ""))));
        vm.expectRevert(IFactory.InvalidSalesManagerAddress.selector);
        proxy.initialize(
            address(p.trexFactory), ZERO, address(p.tokenController), address(p.maxSupplyModule), address(p.governance)
        );
    }

    function test_Factory_initialize_rejects_zero_token_controller() public {
        Factory impl = new Factory();
        Factory proxy = Factory(payable(address(new ERC1967Proxy(address(impl), ""))));
        vm.expectRevert(IFactory.InvalidTokenControllerAddress.selector);
        proxy.initialize(
            address(p.trexFactory), address(p.salesManager), ZERO, address(p.maxSupplyModule), address(p.governance)
        );
    }

    function test_Factory_initialize_rejects_zero_max_supply_module() public {
        Factory impl = new Factory();
        Factory proxy = Factory(payable(address(new ERC1967Proxy(address(impl), ""))));
        vm.expectRevert(IFactory.InvalidMaxSupplyModuleAddress.selector);
        proxy.initialize(
            address(p.trexFactory), address(p.salesManager), address(p.tokenController), ZERO, address(p.governance)
        );
    }

    function test_Factory_initialize_reverts_on_double_init() public {
        Factory impl = new Factory();

        Factory proxy = Factory(payable(address(new ERC1967Proxy(address(impl), ""))));
        proxy.initialize(
            address(p.trexFactory),
            address(p.salesManager),
            address(p.tokenController),
            address(p.maxSupplyModule),
            address(p.governance)
        );

        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        proxy.initialize(
            address(p.trexFactory),
            address(p.salesManager),
            address(p.tokenController),
            address(p.maxSupplyModule),
            address(p.governance)
        );
    }

    // Upgrades / proxy

    function test_UpgradeRequiresRole() public {
        address attacker = vm.addr(77);
        Factory factoryImpl = new Factory();
        vm.prank(attacker);
        vm.expectRevert(IFactory.NotAuthorized.selector);
        p.factory.upgradeTo(address(factoryImpl));
    }

    function test_UpgradeWithRolePreservesState() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        uint256 beforeIndex = p.factory.shareIdIndex();

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "UP",
                    symbol: "UP",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        MaxSupplyModule newModule = new MaxSupplyModule();
        Factory newImpl = new Factory();

        vm.startPrank(multisig);
        p.factory.editMaxSupplyModule(address(newModule));
        address beforeModule = p.factory.maxSupplyModule();
        p.factory.upgradeTo(address(newImpl));
        vm.stopPrank();

        assertEq(p.factory.shareIdIndex(), beforeIndex + 1);
        assertEq(p.factory.maxSupplyModule(), beforeModule);
        address tokenAddr = p.factory.idToShare(p.factory.shareIdIndex());
        assertEq(p.factory.shareToId(tokenAddr), p.factory.shareIdIndex());
    }

    function test_UpgradePreservesTrexFactoryOwnership() public {
        assertEq(p.trexFactory.owner(), address(p.factory));
        Factory newImpl = new Factory();
        vm.prank(multisig);
        p.factory.upgradeTo(address(newImpl));
        assertEq(p.trexFactory.owner(), address(p.factory));
        assertTrue(p.factory.isContractTrexFactoryOwner());
    }

    // createShare authorization and validation

    function test_CreateShare_NotAuthorized() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        address attacker = vm.addr(99);
        vm.prank(attacker);
        vm.expectRevert(IFactory.NotAuthorized.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "ROLE",
                    symbol: "ROL",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );
    }

    function test_AdminGrantsAndRevokesShareDeployerRole() public {
        RoleIds memory roles = _loadRoleIds();
        address attacker = vm.addr(55);
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        // attacker cannot create initially
        vm.prank(attacker);
        vm.expectRevert(IFactory.NotAuthorized.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "R1",
                    symbol: "R1",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        // multisig (admin) grants role
        vm.prank(multisig);
        p.accessManager.grantRole(roles.shareDeployer, attacker, 0);

        // now succeeds
        vm.prank(attacker);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "R2",
                    symbol: "R2",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        // revoke and ensure revert
        vm.prank(multisig);
        p.accessManager.revokeRole(roles.shareDeployer, attacker);
        vm.prank(attacker);
        vm.expectRevert(IFactory.NotAuthorized.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "R3",
                    symbol: "R3",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );
    }

    function test_RogueFactoryCannotCreateShare() public {
        // deploy rogue factory proxy without owning TREXFactory
        Factory factoryImpl = new Factory();
        Factory rogue = Factory(payable(address(new ERC1967Proxy(address(factoryImpl), ""))));
        rogue.initialize(
            address(p.trexFactory),
            address(p.salesManager),
            address(p.tokenController),
            address(p.maxSupplyModule),
            address(p.governance)
        );

        RoleIds memory roles = _loadRoleIds();
        // allow createShare selector on rogue so it passes governance check
        address attacker = vm.addr(77);
        vm.startPrank(multisig);
        p.accessManager
            .setTargetFunctionRole(address(rogue), _toSingle(Factory.createShare.selector), roles.shareDeployer);
        p.accessManager.grantRole(roles.shareDeployer, attacker, 0);
        vm.stopPrank();

        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        vm.prank(attacker);
        vm.expectRevert(IFactory.NotOwnerOfTREXFactory.selector);
        rogue.createShare(
            IFactory.CreateShareParams({
                name: "R",
                symbol: "R",
                decimals: 0,
                owner: multisig,
                tokenAgents: tokenAgents,
                irAgents: irAgents,
                irs: address(p.identityRegistryStorage),
                claimTopics: new uint256[](0),
                issuers: new address[](0),
                issuerClaims: new uint256[][](0),
                maxSupply: DEFAULT_MAX_SUPPLY
            })
        );
    }

    function test_MaxSupplyRequired() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        vm.prank(factoryShareDeployer);
        vm.expectRevert(IFactory.MaxSupplyRequired.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "ZERO",
                    symbol: "ZERO",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: 0
                })
            );
    }

    function test_createShare_reverts_when_maxSupplyModule_unset() public {
        vm.prank(multisig);
        p.factory.editMaxSupplyModule(ZERO);
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        vm.expectRevert(IFactory.MaxSupplyModuleNotSet.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "NOM",
                    symbol: "NOM",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );
    }

    function test_createShare_rejects_any_custom_token_agents() public {
        address[] memory tokenAgents = new address[](1);
        tokenAgents[0] = user1;
        address[] memory irAgents = new address[](0);

        vm.prank(factoryShareDeployer);
        vm.expectRevert(IFactory.CustomTokenAgentsNotAllowed.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "N",
                    symbol: "S",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );
    }

    function test_SalesManagerNotInTokenAgents() public {
        address[] memory tokenAgents = new address[](1);
        tokenAgents[0] = address(p.salesManager);
        address[] memory irAgents = new address[](1);
        irAgents[0] = identityRegistryAgent;

        vm.prank(factoryShareDeployer);
        vm.expectRevert(IFactory.CustomTokenAgentsNotAllowed.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "SM",
                    symbol: "SM",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );
    }

    function test_IRSOwnershipCheck() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        // good IRS transferred to TREXFactory
        IdentityRegistryStorageProxy goodIrsProxy =
            new IdentityRegistryStorageProxy(address(p.trexFactory.getImplementationAuthority()));
        IdentityRegistryStorage(address(goodIrsProxy)).transferOwnership(address(p.trexFactory));

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "WITHIRS",
                    symbol: "WIR",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(goodIrsProxy),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        // bad IRS not transferred
        IdentityRegistryStorageProxy badIrsProxy =
            new IdentityRegistryStorageProxy(address(p.trexFactory.getImplementationAuthority()));
        vm.prank(factoryShareDeployer);
        vm.expectRevert(IFactory.IRSNot0OrOwnedByTREXFactory.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "WITHIRS2",
                    symbol: "WIR2",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(badIrsProxy),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );
    }

    function test_createShare_accepts_zero_irs() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        address tokenAddr = p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "NOIRS",
                    symbol: "NIR",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: ZERO,
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        assertTrue(tokenAddr != address(0));
        assertEq(p.factory.idToShare(p.factory.shareIdIndex()), tokenAddr);
    }

    function test_createShare_reverts_for_more_than_5_ir_agents() public {
        address[] memory tokenAgents = new address[](0);
        address[] memory irAgents = new address[](6);

        vm.prank(factoryShareDeployer);
        vm.expectRevert(IFactory.Max5IRAgents.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "IR6",
                    symbol: "IR6",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );
    }

    function test_createShare_reverts_for_more_than_5_claim_topics() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        uint256[] memory sixClaims = new uint256[](6);

        vm.prank(factoryShareDeployer);
        vm.expectRevert(IFactory.Max5ClaimTopics.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "C",
                    symbol: "I",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: sixClaims,
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );
    }

    function test_createShare_reverts_for_more_than_5_issuers() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        address[] memory issuers = new address[](6);

        vm.prank(factoryShareDeployer);
        vm.expectRevert(IFactory.Max5Issuers.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "C2",
                    symbol: "I2",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: issuers,
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );
    }

    function test_createShare_reverts_for_issuer_claim_length_mismatch() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        uint256[][] memory issuerClaims = new uint256[][](0);

        address[] memory oneIssuer = new address[](1);
        oneIssuer[0] = claimIssuer;
        vm.prank(factoryShareDeployer);
        vm.expectRevert(IFactory.ClaimIssuerLengthMismatch.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "C3",
                    symbol: "I3",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: oneIssuer,
                    issuerClaims: issuerClaims,
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        uint256[][] memory oneIssuerClaim = new uint256[][](1);

        vm.prank(factoryShareDeployer);
        vm.expectRevert(IFactory.ClaimIssuerLengthMismatch.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "C4",
                    symbol: "I4",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: oneIssuerClaim,
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );
    }

    // createShare deployment results

    function test_CreateShareIndexesMappings() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        address tokenAddr = p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "ACME",
                    symbol: "ACM",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        uint256 lastId = p.factory.shareIdIndex();
        assertEq(p.factory.idToShare(lastId), tokenAddr);
        assertEq(p.factory.shareToId(tokenAddr), lastId);
    }

    function test_ShareIdIndexIncrements() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        uint256 beforeIndex = p.factory.shareIdIndex();

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "X",
                    symbol: "X",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );
        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "Y",
                    symbol: "Y",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        assertEq(p.factory.shareIdIndex(), beforeIndex + 2);
    }

    function test_CreateShare_UniqueNameSymbol() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "Share1",
                    symbol: "SHR1",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "Share2",
                    symbol: "SHR2",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        assertEq(p.factory.shareIdIndex(), 2);
    }

    function test_CreateShare_DuplicateNameDifferentSymbol() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        address firstToken = p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "Total",
                    symbol: "TOT",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        vm.prank(factoryShareDeployer);
        address secondToken = p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "Total",
                    symbol: "TOTA",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        assertEq(p.factory.shareIdIndex(), 2);
        assertTrue(secondToken != firstToken);
    }

    function test_CreateShare_RejectDuplicateSymbol() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "Total",
                    symbol: "TOT",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        vm.prank(factoryShareDeployer);
        vm.expectRevert(IFactory.SymbolAlreadyUsed.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "Totality",
                    symbol: "TOT",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );
    }

    function test_createShare_emits_ShareCreated() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        vm.expectEmit(true, false, false, true, address(p.factory));
        emit ShareCreated(1, address(0), "EVT", "EVT", 0);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "EVT",
                    symbol: "EVT",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );
    }

    function test_createShare_with_6_decimals() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "D6",
                    symbol: "D6",
                    decimals: 6,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        Token token = Token(p.factory.idToShare(p.factory.shareIdIndex()));
        assertEq(token.decimals(), 6);
    }

    function test_createShare_with_18_decimals() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "D18",
                    symbol: "D18",
                    decimals: 18,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        Token token = Token(p.factory.idToShare(p.factory.shareIdIndex()));
        assertEq(token.decimals(), 18);
    }

    function test_createShare_with_initial_claim_topics_and_trusted_issuers() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        uint256[] memory topics = new uint256[](1);
        topics[0] = 7;

        address[] memory issuers = new address[](1);
        issuers[0] = address(p.claimIssuer);

        uint256[][] memory issuerClaims = new uint256[][](1);
        issuerClaims[0] = topics;

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "CLM",
                    symbol: "CLM",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: topics,
                    issuers: issuers,
                    issuerClaims: issuerClaims,
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        Token token = Token(p.factory.idToShare(p.factory.shareIdIndex()));
        IdentityRegistry ir = IdentityRegistry(address(token.identityRegistry()));
        ClaimTopicsRegistry ctr = ClaimTopicsRegistry(address(ir.topicsRegistry()));
        TrustedIssuersRegistry tir = TrustedIssuersRegistry(address(ir.issuersRegistry()));

        uint256[] memory topicsOut = ctr.getClaimTopics();
        assertEq(topicsOut.length, 1);
        assertEq(topicsOut[0], 7);
        assertTrue(tir.isTrustedIssuer(address(p.claimIssuer)));

        uint256[] memory issuerTopics = tir.getTrustedIssuerClaimTopics(IClaimIssuer(address(p.claimIssuer)));
        assertEq(issuerTopics.length, 1);
        assertEq(issuerTopics[0], 7);
    }

    function test_createShare_installs_only_expected_token_agents() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "AGT",
                    symbol: "AGT",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        Token token = Token(p.factory.idToShare(p.factory.shareIdIndex()));
        assertTrue(token.isAgent(address(p.tokenController)));
        assertTrue(token.isAgent(address(p.salesManager)));
    }

    function test_createShare_salesManager_can_mint_but_arbitrary_agent_is_not_injected() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "MNT",
                    symbol: "MNT",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: DEFAULT_MAX_SUPPLY
                })
            );

        Token token = Token(p.factory.idToShare(p.factory.shareIdIndex()));
        assertFalse(token.isAgent(vm.addr(9999)));
        assertTrue(token.isAgent(address(p.salesManager)));
    }

    function test_MaxSupplyCapBoundOnDeployment() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "POST",
                    symbol: "POST",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: 777
                })
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

    function test_MaxSupplyEnforced() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "CAP",
                    symbol: "CAP",
                    decimals: 0,
                    owner: multisig,
                    tokenAgents: tokenAgents,
                    irAgents: irAgents,
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: 1000
                })
            );

        address tokenAddr = p.factory.idToShare(p.factory.shareIdIndex());
        Token token = Token(tokenAddr);
        address irAddr = address(token.identityRegistry());

        // register identity
        IIdentity buyerIdentity = IIdentity(address(new Identity(buyer, false)));
        vm.prank(identityRegistryAgent);
        IdentityRegistry(irAddr).registerIdentity(buyer, buyerIdentity, 1);

        // set capabilities and roles already granted
        uint256 caps =
            p.tokenController.PAUSABLE_BIT() | p.tokenController.MINTABLE_BIT() | p.tokenController.BURNABLE_BIT();
        vm.prank(factoryShareDeployer);
        p.tokenController.setTokenCapsInitial(tokenAddr, caps);

        vm.startPrank(tokenAgent);
        p.tokenController.unpause(tokenAddr);
        p.tokenController.mint(tokenAddr, buyer, 600);

        uint256 supplyBefore = token.totalSupply();
        vm.expectRevert(bytes("Compliance not followed"));
        p.tokenController.mint(tokenAddr, buyer, 500);
        assertEq(token.totalSupply(), supplyBefore);

        p.tokenController.burn(tokenAddr, buyer, 200);
        p.tokenController.mint(tokenAddr, buyer, 200);
        vm.stopPrank();
    }

    // deployShareSuite

    function test_deployShareSuite_NotAuthorized() public {
        ITREXFactory.TokenDetails memory td = ITREXFactory.TokenDetails({
            owner: multisig,
            name: "NoAuth",
            symbol: "NAU",
            decimals: 0,
            irs: address(p.identityRegistryStorage),
            ONCHAINID: ZERO,
            irAgents: _single(identityRegistryAgent),
            tokenAgents: _single(tokenAgent),
            complianceModules: _single(address(p.maxSupplyModule)),
            complianceSettings: _singleBytes(abi.encodeWithSignature("setMaxSupply(uint256)", DEFAULT_MAX_SUPPLY))
        });

        ITREXFactory.ClaimDetails memory cd = ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });

        vm.prank(vm.addr(79));
        vm.expectRevert(IFactory.NotAuthorized.selector);
        p.factory.deployShareSuite("NOAUTH", td, cd);
    }

    function test_deployShareSuite_rejects_rogue_factory() public {
        Factory factoryImpl = new Factory();
        Factory rogue = Factory(payable(address(new ERC1967Proxy(address(factoryImpl), ""))));
        rogue.initialize(
            address(p.trexFactory),
            address(p.salesManager),
            address(p.tokenController),
            address(p.maxSupplyModule),
            address(p.governance)
        );

        RoleIds memory roles = _loadRoleIds();
        address attacker = vm.addr(80);
        vm.startPrank(multisig);
        p.accessManager.setTargetFunctionRole(address(rogue), _toSingle(Factory.deployShareSuite.selector), roles.admin);
        p.accessManager.grantRole(roles.admin, attacker, 0);
        vm.stopPrank();

        ITREXFactory.TokenDetails memory td = ITREXFactory.TokenDetails({
            owner: multisig,
            name: "Rogue",
            symbol: "RGE",
            decimals: 0,
            irs: address(p.identityRegistryStorage),
            ONCHAINID: ZERO,
            irAgents: _single(identityRegistryAgent),
            tokenAgents: _single(tokenAgent),
            complianceModules: _single(address(p.maxSupplyModule)),
            complianceSettings: _singleBytes(abi.encodeWithSignature("setMaxSupply(uint256)", DEFAULT_MAX_SUPPLY))
        });
        ITREXFactory.ClaimDetails memory cd = ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });

        vm.prank(attacker);
        vm.expectRevert(IFactory.NotOwnerOfTREXFactory.selector);
        rogue.deployShareSuite("ROGUE", td, cd);
    }

    function test_deployShareSuite_rejects_more_than_5_token_agents() public {
        address[] memory t6 = new address[](6);

        for (uint256 i = 0; i < 6; i++) {
            t6[i] = vm.addr(5000 + uint32(i));
        }

        ITREXFactory.TokenDetails memory td = ITREXFactory.TokenDetails({
            owner: multisig,
            name: "SixAg",
            symbol: "S6A",
            decimals: 0,
            irs: address(p.identityRegistryStorage),
            ONCHAINID: ZERO,
            irAgents: _single(identityRegistryAgent),
            tokenAgents: t6,
            complianceModules: _single(address(p.maxSupplyModule)),
            complianceSettings: _singleBytes(abi.encodeWithSignature("setMaxSupply(uint256)", DEFAULT_MAX_SUPPLY))
        });

        ITREXFactory.ClaimDetails memory cd = ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });

        vm.startPrank(multisig);
        vm.expectRevert(IFactory.Max5TokenAgents.selector);
        p.factory.deployShareSuite("S6", td, cd);
        vm.stopPrank();
    }

    function test_deployShareSuite_accepts_5_token_agents() public {
        address[] memory t5 = new address[](5);

        for (uint256 i = 0; i < 5; i++) {
            t5[i] = vm.addr(6000 + uint32(i));
        }

        ITREXFactory.TokenDetails memory td = ITREXFactory.TokenDetails({
            owner: multisig,
            name: "FiveAg",
            symbol: "F5A",
            decimals: 0,
            irs: address(p.identityRegistryStorage),
            ONCHAINID: ZERO,
            irAgents: _single(identityRegistryAgent),
            tokenAgents: t5,
            complianceModules: _single(address(p.maxSupplyModule)),
            complianceSettings: _singleBytes(abi.encodeWithSignature("setMaxSupply(uint256)", DEFAULT_MAX_SUPPLY))
        });

        ITREXFactory.ClaimDetails memory cd = ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });

        vm.prank(multisig);
        address tokenAddr = p.factory.deployShareSuite("F5", td, cd);
        assertTrue(tokenAddr != address(0));
    }

    function test_SaltCollisionDeployShareSuite() public {
        ITREXFactory.TokenDetails memory td = ITREXFactory.TokenDetails({
            owner: multisig,
            name: "A",
            symbol: "A",
            decimals: 0,
            irs: address(p.identityRegistryStorage),
            ONCHAINID: ZERO,
            irAgents: _single(identityRegistryAgent),
            tokenAgents: _single(tokenAgent),
            complianceModules: _single(address(p.maxSupplyModule)),
            complianceSettings: _singleBytes(abi.encodeWithSignature("setMaxSupply(uint256)", DEFAULT_MAX_SUPPLY))
        });
        ITREXFactory.ClaimDetails memory cd = ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });

        vm.startPrank(multisig);
        p.factory.deployShareSuite("SALT", td, cd);
        vm.expectRevert(IFactory.SaltAlreadyUsed.selector);
        td.name = "B";
        td.symbol = "B";
        p.factory.deployShareSuite("SALT", td, cd);
        vm.stopPrank();
    }

    // Ownership / configuration / views

    function test_TrexFactoryOwnershipTransferred() public view {
        assertEq(p.trexFactory.owner(), address(p.factory));
        assertTrue(p.factory.isContractTrexFactoryOwner());
    }

    function test_EditMaxSupplyModule() public {
        MaxSupplyModule module = new MaxSupplyModule();
        vm.prank(multisig);
        vm.expectEmit(false, false, false, true, address(p.factory));
        emit EditMaxSupplyModule(address(module));
        p.factory.editMaxSupplyModule(address(module));
        assertEq(p.factory.maxSupplyModule(), address(module));
    }

    function test_editMaxSupplyModule_NotAuthorized() public {
        MaxSupplyModule module = new MaxSupplyModule();
        address attacker = vm.addr(98);

        vm.prank(attacker);
        vm.expectRevert(IFactory.NotAuthorized.selector);
        p.factory.editMaxSupplyModule(address(module));
    }

    function test_trexFactory_getter() public view {
        assertEq(p.factory.trexFactory(), address(p.trexFactory));
    }

    // Helpers

    function _defaultAgents() internal view returns (address[] memory tokenAgents, address[] memory irAgents) {
        tokenAgents = new address[](0);
        irAgents = new address[](1);
        irAgents[0] = identityRegistryAgent;
    }
}
