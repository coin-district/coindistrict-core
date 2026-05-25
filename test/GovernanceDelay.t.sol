// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {ProtocolFixture, Protocol, Accounts, RoleIds, IUUPSUpgradeableLike} from "./fixtures/ProtocolFixture.sol";
import {ShareTestUtils} from "./utils/ShareTestUtils.sol";
import {Permission} from "./fixtures/Permissions.sol";
import {Factory} from "contracts/Factory.sol";
import {SalesManager} from "contracts/SalesManager.sol";
import {TokenController} from "contracts/TokenController.sol";
import {IAccessManager} from "contracts/interfaces/IAccessManager.sol";
import {Token} from "@erc3643org/erc-3643/contracts/token/Token.sol";
import {Identity} from "@onchain-id/solidity/contracts/Identity.sol";
import {IIdentity} from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {MockAggregatorV3} from "contracts/mocks/MockAggregatorV3.sol";

interface IAccessManagerOps {
    function schedule(address target, bytes calldata data, uint48 when) external returns (bytes32, uint32);
    function execute(address target, bytes calldata data) external payable returns (uint32);
}

contract GovernanceDelayTest is Test, ProtocolFixture {
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    Protocol internal p;
    Accounts internal acc;
    RoleIds internal roles;

    function setUp() public {
        acc = defaultAccounts();
        p = deployProtocol(acc);
        roles = _loadRoleIds();
        Permission[] memory perms = _defaultPermissions(p);
        _applyPermissions(p, acc.multisig, perms);
        addGlobalIrAgents(p, acc);

        vm.startPrank(acc.multisig);
        p.accessManager.grantRole(roles.shareDeployer, acc.factoryShareDeployer, 60);
        p.accessManager.grantRole(roles.salesOperator, acc.salesManagerSalesOperator, 60);
        p.accessManager.grantRole(roles.minter, acc.tokenAgent, 60);
        vm.stopPrank();
    }

    function test_delayed_role_direct_call_is_not_immediate() public view {
        (bool immediate, uint32 delay) =
            p.governance.canCall(acc.factoryShareDeployer, address(p.factory), Factory.createShare.selector);
        assertFalse(immediate);
        assertEq(delay, 60);
        assertFalse(p.governance.hasRole(acc.factoryShareDeployer, address(p.factory), Factory.createShare.selector));
    }

    function test_delayed_role_requires_access_manager_execution_for_factory_action() public {
        bytes memory data = abi.encodeWithSelector(
            Factory.createShare.selector,
            "DELAY",
            "DLY",
            uint8(0),
            acc.multisig,
            new address[](0),
            _single(acc.identityRegistryAgent),
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            1000
        );

        vm.prank(acc.factoryShareDeployer);
        vm.expectRevert();
        p.factory
            .createShare(
                "DELAY",
                "DLY",
                0,
                acc.multisig,
                new address[](0),
                _single(acc.identityRegistryAgent),
                address(p.identityRegistryStorage),
                new uint256[](0),
                new address[](0),
                new uint256[][](0),
                1000
            );

        vm.prank(acc.factoryShareDeployer);
        IAccessManagerOps(address(p.accessManager)).schedule(address(p.factory), data, 0);
        vm.warp(block.timestamp + 60);
        vm.prank(acc.factoryShareDeployer);
        IAccessManagerOps(address(p.accessManager)).execute(address(p.factory), data);
        assertTrue(p.factory.shareIdIndex() > 0);
    }

    function test_delayed_role_requires_access_manager_execution_for_sales_action() public {
        // Grant multisig shareDeployer + pauser + salesConfig (no delay) for token setup
        vm.startPrank(acc.multisig);
        p.accessManager.grantRole(roles.shareDeployer, acc.multisig, 0);
        p.accessManager.grantRole(roles.pauser, acc.multisig, 0);
        p.accessManager.grantRole(roles.salesConfig, acc.multisig, 0);
        vm.stopPrank();

        address[] memory irAgents = new address[](1);
        irAgents[0] = acc.identityRegistryAgent;
        vm.prank(acc.multisig);
        p.factory
            .createShare(
                "DLS",
                "DLS",
                0,
                acc.multisig,
                new address[](0),
                irAgents,
                address(p.identityRegistryStorage),
                new uint256[](0),
                new address[](0),
                new uint256[][](0),
                1000
            );
        address tokenAddr = p.factory.idToShare(p.factory.shareIdIndex());

        MockToken stable = new MockToken("USD", "USD", 6);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(acc.multisig);
        p.tokenController.setTokenCapsInitial(tokenAddr, p.tokenController.PAUSABLE_BIT());
        p.tokenController.unpause(tokenAddr);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        address[] memory paymentTokens = new address[](1);
        paymentTokens[0] = address(stable);

        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);
        bytes memory data = abi.encodeWithSelector(
            SalesManager.createSale.selector,
            tokenAddr,
            paymentTokens,
            acc.multisig,
            uint256(100),
            uint256(1e8),
            start,
            deadline
        );

        // Direct call reverts — salesOperator has a 60s delay
        vm.prank(acc.salesManagerSalesOperator);
        vm.expectRevert();
        p.salesManager.createSale(tokenAddr, paymentTokens, acc.multisig, 100, 1e8, start, deadline);

        uint256 saleCountBefore = p.salesManager.saleCount();

        // Schedule + execute after 60s succeeds
        vm.prank(acc.salesManagerSalesOperator);
        IAccessManagerOps(address(p.accessManager)).schedule(address(p.salesManager), data, 0);
        vm.warp(block.timestamp + 60);
        vm.prank(acc.salesManagerSalesOperator);
        IAccessManagerOps(address(p.accessManager)).execute(address(p.salesManager), data);

        assertEq(p.salesManager.saleCount(), saleCountBefore + 1);
    }

    function test_delayed_role_requires_access_manager_execution_for_token_controller_action() public {
        // Grant multisig shareDeployer + pauser (no delay) for token setup — not the subject under test
        vm.startPrank(acc.multisig);
        p.accessManager.grantRole(roles.shareDeployer, acc.multisig, 0);
        p.accessManager.grantRole(roles.pauser, acc.multisig, 0);
        vm.stopPrank();

        address[] memory irAgents = new address[](1);
        irAgents[0] = acc.identityRegistryAgent;
        vm.prank(acc.multisig);
        p.factory
            .createShare(
                "DLM",
                "DLM",
                0,
                acc.multisig,
                new address[](0),
                irAgents,
                address(p.identityRegistryStorage),
                new uint256[](0),
                new address[](0),
                new uint256[][](0),
                1000
            );
        address tokenAddr = p.factory.idToShare(p.factory.shareIdIndex());
        Token token = Token(tokenAddr);

        vm.startPrank(acc.multisig);
        p.tokenController
            .setTokenCapsInitial(tokenAddr, p.tokenController.MINTABLE_BIT() | p.tokenController.PAUSABLE_BIT());
        p.tokenController.unpause(tokenAddr);
        vm.stopPrank();

        address recipient = vm.addr(555);
        IIdentity recipientId = IIdentity(address(new Identity(recipient, false)));
        vm.prank(acc.identityRegistryAgent);
        p.identityRegistry.registerIdentity(recipient, recipientId, 1);

        bytes memory data = abi.encodeWithSelector(TokenController.mint.selector, tokenAddr, recipient, uint256(10));

        // Direct call reverts — minter has a 60s delay
        vm.prank(acc.tokenAgent);
        vm.expectRevert();
        p.tokenController.mint(tokenAddr, recipient, 10);

        // Schedule + execute after 60s succeeds
        vm.prank(acc.tokenAgent);
        IAccessManagerOps(address(p.accessManager)).schedule(address(p.tokenController), data, 0);
        vm.warp(block.timestamp + 60);
        vm.prank(acc.tokenAgent);
        IAccessManagerOps(address(p.accessManager)).execute(address(p.tokenController), data);

        assertEq(token.balanceOf(recipient), 10);
    }

    function test_delayed_upgradeToAndCall_factory_succeeds() public {
        address delayedUpgrader = acc.user1;
        _grantDelayedUpgrader(delayedUpgrader);

        Factory newImpl = new Factory();
        uint256 shareIdBefore = p.factory.shareIdIndex();

        _scheduleAndExecuteUpgradeToAndCall(
            delayedUpgrader, address(p.factory), address(newImpl), abi.encodeWithSignature("shareIdIndex()")
        );

        assertEq(p.factory.shareIdIndex(), shareIdBefore);
    }

    function test_delayed_upgradeToAndCall_salesManager_succeeds() public {
        address delayedUpgrader = acc.user1;
        _grantDelayedUpgrader(delayedUpgrader);

        SalesManager newImpl = new SalesManager();
        uint256 saleCountBefore = p.salesManager.saleCount();

        _scheduleAndExecuteUpgradeToAndCall(
            delayedUpgrader, address(p.salesManager), address(newImpl), abi.encodeWithSignature("saleCount()")
        );

        assertEq(p.salesManager.saleCount(), saleCountBefore);
    }

    function test_delayed_upgradeToAndCall_tokenController_succeeds() public {
        address delayedUpgrader = acc.user1;
        _grantDelayedUpgrader(delayedUpgrader);

        TokenController newImpl = new TokenController();
        uint256 initializedBitBefore = p.tokenController.INITIALIZED_BIT();

        _scheduleAndExecuteUpgradeToAndCall(
            delayedUpgrader, address(p.tokenController), address(newImpl), abi.encodeWithSignature("INITIALIZED_BIT()")
        );

        assertEq(p.tokenController.INITIALIZED_BIT(), initializedBitBefore);
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
    }

    function _grantDelayedUpgrader(address account) internal {
        vm.prank(acc.multisig);
        p.accessManager.grantRole(roles.upgrader, account, 60);
    }

    function _scheduleAndExecuteUpgradeToAndCall(
        address caller,
        address target,
        address newImpl,
        bytes memory setupCall
    ) internal {
        bytes memory data = abi.encodeWithSelector(IUUPSUpgradeableLike.upgradeToAndCall.selector, newImpl, setupCall);

        vm.prank(caller);
        IAccessManagerOps(address(p.accessManager)).schedule(target, data, 0);

        vm.warp(block.timestamp + 60);

        vm.prank(caller);
        IAccessManagerOps(address(p.accessManager)).execute(target, data);

        assertEq(_implementationOf(target), newImpl);
    }
}
