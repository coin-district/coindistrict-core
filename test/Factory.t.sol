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

    function _setRoleForSelector(address target, string memory signature, uint64 roleId) internal {
        bytes4 selector = bytes4(keccak256(bytes(signature)));
        p.accessManager.setTargetFunctionRole(target, _toSingle(selector), roleId);
    }

    // --- Tests (partial subset) ---

    function test_TrexFactoryOwnershipTransferred() public view {
        assertEq(p.trexFactory.owner(), address(p.factory));
        assertTrue(p.factory.isContractTrexFactoryOwner());
    }

    function test_CreateShareIndexesMappings() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        address tokenAddr = p.factory
            .createShare(
                "ACME",
                "ACM",
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
        p.factory
            .createShare(
                "Share1",
                "SHR1",
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
        p.factory
            .createShare(
                "Share2",
                "SHR2",
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
        address firstToken = p.factory
            .createShare(
                "Total",
                "TOT",
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
        address secondToken = p.factory
            .createShare(
                "Total",
                "TOTA",
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
        assertTrue(secondToken != firstToken);
    }

    function test_CreateShare_RejectDuplicateSymbol() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                "Total",
                "TOT",
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
        vm.expectRevert(bytes("Factory_SymbolAlreadyUsed"));
        p.factory
            .createShare(
                "Totality",
                "TOT",
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
        vm.expectEmit(false, false, false, true, address(p.factory));
        emit EditMaxSupplyModule(address(module));
        p.factory.editMaxSupplyModule(address(module));
        assertEq(p.factory.maxSupplyModule(), address(module));
    }

    function test_editMaxSupplyModule_NotAuthorized() public {
        MaxSupplyModule module = new MaxSupplyModule();
        address attacker = vm.addr(98);

        vm.prank(attacker);
        vm.expectRevert(bytes("Factory_NotAuthorized"));
        p.factory.editMaxSupplyModule(address(module));
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
                "WITHIRS",
                "WIR",
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
        IdentityRegistryStorageProxy badIrsProxy =
            new IdentityRegistryStorageProxy(address(p.trexFactory.getImplementationAuthority()));
        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes("Factory_IRSNot0OrOwnedByTREXFactory"));
        p.factory
            .createShare(
                "WITHIRS2",
                "WIR2",
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

    function test_createShare_rejects_any_custom_token_agents() public {
        address[] memory tokenAgents = new address[](1);
        tokenAgents[0] = user1;
        address[] memory irAgents = new address[](0);

        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes("Factory_CustomTokenAgentsNotAllowed"));
        p.factory
            .createShare(
                "N",
                "S",
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
        vm.expectRevert(bytes("Factory_CustomTokenAgentsNotAllowed"));
        p.factory
            .createShare(
                "SM",
                "SM",
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
        vm.expectRevert(bytes("Factory_MaxSupplyRequired"));
        p.factory
            .createShare(
                "ZERO",
                "ZERO",
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
        p.factory
            .createShare(
                "X",
                "X",
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
        p.factory
            .createShare(
                "Y",
                "Y",
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
        vm.expectRevert(bytes("Factory_NotAuthorized"));
        p.factory
            .createShare(
                "ROLE",
                "ROL",
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

    function test_createShare_reverts_for_more_than_5_claim_topics() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        uint256[] memory sixClaims = new uint256[](6);

        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes("Factory_Max5ClaimTopics"));
        p.factory
            .createShare(
                "C",
                "I",
                0,
                multisig,
                tokenAgents,
                irAgents,
                address(p.identityRegistryStorage),
                sixClaims,
                new address[](0),
                new uint256[][](0),
                DEFAULT_MAX_SUPPLY
            );
    }

    function test_createShare_reverts_for_more_than_5_ir_agents() public {
        address[] memory tokenAgents = new address[](0);
        address[] memory irAgents = new address[](6);

        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes("Factory_Max5IRAgents"));
        p.factory
            .createShare(
                "IR6",
                "IR6",
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

    function test_createShare_accepts_zero_irs() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        address tokenAddr = p.factory
            .createShare(
                "NOIRS",
                "NIR",
                0,
                multisig,
                tokenAgents,
                irAgents,
                ZERO,
                new uint256[](0),
                new address[](0),
                new uint256[][](0),
                DEFAULT_MAX_SUPPLY
            );

        assertTrue(tokenAddr != address(0));
        assertEq(p.factory.idToShare(p.factory.shareIdIndex()), tokenAddr);
    }

    function test_createShare_reverts_for_more_than_5_issuers() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        address[] memory issuers = new address[](6);

        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes("Factory_Max5Issuers"));
        p.factory
            .createShare(
                "C2",
                "I2",
                0,
                multisig,
                tokenAgents,
                irAgents,
                address(p.identityRegistryStorage),
                new uint256[](0),
                issuers,
                new uint256[][](0),
                DEFAULT_MAX_SUPPLY
            );
    }

    function test_createShare_reverts_for_issuer_claim_length_mismatch() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        uint256[][] memory issuerClaims = new uint256[][](0);

        address[] memory oneIssuer = new address[](1);
        oneIssuer[0] = claimIssuer;
        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes("Factory_ClaimIssuerLengthMismatch"));
        p.factory
            .createShare(
                "C3",
                "I3",
                0,
                multisig,
                tokenAgents,
                irAgents,
                address(p.identityRegistryStorage),
                new uint256[](0),
                oneIssuer,
                issuerClaims,
                DEFAULT_MAX_SUPPLY
            );

        uint256[][] memory oneIssuerClaim = new uint256[][](1);

        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes("Factory_ClaimIssuerLengthMismatch"));
        p.factory
            .createShare(
                "C4",
                "I4",
                0,
                multisig,
                tokenAgents,
                irAgents,
                address(p.identityRegistryStorage),
                new uint256[](0),
                new address[](0),
                oneIssuerClaim,
                DEFAULT_MAX_SUPPLY
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
        _setRoleForSelector(
            address(rogue),
            "createShare(string,string,uint8,address,address[],address[],address,uint256[],address[],uint256[][],uint256)",
            roles.shareDeployer
        );
        p.accessManager.grantRole(roles.shareDeployer, attacker, 0);
        vm.stopPrank();

        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        vm.prank(attacker);
        vm.expectRevert(bytes("Factory_NotOwnerOfTREXFactory"));
        rogue.createShare(
            "R",
            "R",
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

    function test_createShare_emits_ShareCreated() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        vm.expectEmit(true, false, false, true, address(p.factory));
        emit ShareCreated(1, address(0), "EVT", "EVT", 0);
        p.factory
            .createShare(
                "EVT",
                "EVT",
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
        p.factory
            .createShare(
                "CAP",
                "CAP",
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

    function test_UpgradeRequiresRole() public {
        address attacker = vm.addr(77);
        Factory factoryImpl = new Factory();
        vm.prank(attacker);
        vm.expectRevert(bytes("Factory_NotAuthorized"));
        p.factory.upgradeTo(address(factoryImpl));
    }

    function test_UpgradeWithRolePreservesState() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        uint256 beforeIndex = p.factory.shareIdIndex();

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                "UP",
                "UP",
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

    function test_MaxSupplyCapBoundOnDeployment() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();
        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                "POST",
                "POST",
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
        RoleIds memory roles = _loadRoleIds();
        address attacker = vm.addr(55);
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        // attacker cannot create initially
        vm.prank(attacker);
        vm.expectRevert(bytes("Factory_NotAuthorized"));
        p.factory
            .createShare(
                "R1",
                "R1",
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
        p.accessManager.grantRole(roles.shareDeployer, attacker, 0);

        // now succeeds
        vm.prank(attacker);
        p.factory
            .createShare(
                "R2",
                "R2",
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
        p.accessManager.revokeRole(roles.shareDeployer, attacker);
        vm.prank(attacker);
        vm.expectRevert(bytes("Factory_NotAuthorized"));
        p.factory
            .createShare(
                "R3",
                "R3",
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
        vm.expectRevert(bytes("Factory_SaltAlreadyUsed"));
        td.name = "B";
        td.symbol = "B";
        p.factory.deployShareSuite("SALT", td, cd);
        vm.stopPrank();
    }

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
        vm.expectRevert(bytes("Factory_NotAuthorized"));
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
        vm.expectRevert(bytes("Factory_NotOwnerOfTREXFactory"));
        rogue.deployShareSuite("ROGUE", td, cd);
    }

    function test_UpgradePreservesTrexFactoryOwnership() public {
        assertEq(p.trexFactory.owner(), address(p.factory));
        Factory newImpl = new Factory();
        vm.prank(multisig);
        p.factory.upgradeTo(address(newImpl));
        assertEq(p.trexFactory.owner(), address(p.factory));
        assertTrue(p.factory.isContractTrexFactoryOwner());
    }

    function test_Factory_initialize_rejects_zero_governance() public {
        Factory impl = new Factory();
        Factory proxy = Factory(payable(address(new ERC1967Proxy(address(impl), ""))));
        vm.expectRevert(bytes("Factory_InvalidGovernanceAddress"));
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
        vm.expectRevert(bytes("Factory_InvalidTREXFactoryAddress"));
        proxy.initialize(
            ZERO, address(p.salesManager), address(p.tokenController), address(p.maxSupplyModule), address(p.governance)
        );
    }

    function test_Factory_initialize_rejects_zero_sales_manager() public {
        Factory impl = new Factory();
        Factory proxy = Factory(payable(address(new ERC1967Proxy(address(impl), ""))));
        vm.expectRevert(bytes("Factory_InvalidSalesManagerAddress"));
        proxy.initialize(
            address(p.trexFactory), ZERO, address(p.tokenController), address(p.maxSupplyModule), address(p.governance)
        );
    }

    function test_Factory_initialize_rejects_zero_token_controller() public {
        Factory impl = new Factory();
        Factory proxy = Factory(payable(address(new ERC1967Proxy(address(impl), ""))));
        vm.expectRevert(bytes("Factory_InvalidTokenControllerAddress"));
        proxy.initialize(
            address(p.trexFactory), address(p.salesManager), ZERO, address(p.maxSupplyModule), address(p.governance)
        );
    }

    function test_Factory_initialize_rejects_zero_max_supply_module() public {
        Factory impl = new Factory();
        Factory proxy = Factory(payable(address(new ERC1967Proxy(address(impl), ""))));
        vm.expectRevert(bytes("Factory_InvalidMaxSupplyModuleAddress"));
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
        vm.expectRevert(bytes("Factory_Max5TokenAgents"));
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

    function test_createShare_reverts_when_maxSupplyModule_unset() public {
        vm.prank(multisig);
        p.factory.editMaxSupplyModule(ZERO);
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        vm.expectRevert(bytes("Factory_MaxSupplyModuleNotSet"));
        p.factory
            .createShare(
                "NOM",
                "NOM",
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

    function test_createShare_with_6_decimals() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                "D6",
                "D6",
                6,
                multisig,
                tokenAgents,
                irAgents,
                address(p.identityRegistryStorage),
                new uint256[](0),
                new address[](0),
                new uint256[][](0),
                DEFAULT_MAX_SUPPLY
            );

        Token token = Token(p.factory.idToShare(p.factory.shareIdIndex()));
        assertEq(token.decimals(), 6);
    }

    function test_createShare_with_18_decimals() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                "D18",
                "D18",
                18,
                multisig,
                tokenAgents,
                irAgents,
                address(p.identityRegistryStorage),
                new uint256[](0),
                new address[](0),
                new uint256[][](0),
                DEFAULT_MAX_SUPPLY
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
                "CLM",
                "CLM",
                0,
                multisig,
                tokenAgents,
                irAgents,
                address(p.identityRegistryStorage),
                topics,
                issuers,
                issuerClaims,
                DEFAULT_MAX_SUPPLY
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
                "AGT",
                "AGT",
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

        Token token = Token(p.factory.idToShare(p.factory.shareIdIndex()));
        assertTrue(token.isAgent(address(p.tokenController)));
        assertTrue(token.isAgent(address(p.salesManager)));
    }

    function test_createShare_salesManager_can_mint_but_arbitrary_agent_is_not_injected() public {
        (address[] memory tokenAgents, address[] memory irAgents) = _defaultAgents();

        vm.prank(factoryShareDeployer);
        p.factory
            .createShare(
                "MNT",
                "MNT",
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

        Token token = Token(p.factory.idToShare(p.factory.shareIdIndex()));
        assertFalse(token.isAgent(vm.addr(9999)));
        assertTrue(token.isAgent(address(p.salesManager)));
    }

    function test_trexFactory_getter() public view {
        assertEq(p.factory.trexFactory(), address(p.trexFactory));
    }

    // helpers
    function _defaultAgents() internal view returns (address[] memory tokenAgents, address[] memory irAgents) {
        tokenAgents = new address[](0);
        irAgents = new address[](1);
        irAgents[0] = identityRegistryAgent;
    }
}
