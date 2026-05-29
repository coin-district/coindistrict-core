// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {ProtocolFixture, Protocol, Accounts, RoleIds, IUUPSUpgradeableLike} from "./fixtures/ProtocolFixture.sol";
import {ShareTestUtils} from "./utils/ShareTestUtils.sol";
import {SalesManager} from "contracts/SalesManager.sol";
import {Factory} from "contracts/Factory.sol";
import {IFactory} from "contracts/IFactory.sol";
import {TokenController} from "contracts/TokenController.sol";
import {ITokenController} from "contracts/ITokenController.sol";
import {Token} from "@erc3643org/erc-3643/contracts/token/Token.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {ITREXFactory} from "@erc3643org/erc-3643/contracts/factory/ITREXFactory.sol";

contract RoleMatrixTest is Test, ProtocolFixture {
    using ShareTestUtils for Protocol;

    Protocol internal p;
    Accounts internal acc;

    function setUp() public {
        acc = defaultAccounts();
        p = deployProtocol(acc);
        defaultRoleSetup(p, acc);
        addGlobalIrAgents(p, acc);

        RoleIds memory roles = _loadRoleIds();
        _grantRole(p, acc.multisig, roles.minter, acc.user1);
        _grantRole(p, acc.multisig, roles.freezer, acc.user2);
    }

    function test_salesConfig_cannot_create_or_operate_sales() public {
        vm.startPrank(acc.salesManagerSalesConfig);
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.createSale(address(1), _single(address(2)), acc.multisig, 1, 1e8, 100, 200);
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.cancelSale(0);
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.pauseSale(0);
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.updateSalePriceUsdPerShare(0, 1e8);
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.fulfillFiatOrder(0, 1, acc.buyer, bytes32(uint256(1)));
        vm.stopPrank();
    }

    function test_salesOperator_cannot_configure_or_withdraw() public {
        vm.startPrank(acc.salesManagerSalesOperator);
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.setAllowedPaymentToken(address(1), true);
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.setPaymentTokenOracle(address(1), address(2), 1 hours, type(uint256).max);
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.withdrawFunds(_single(address(1)), acc.multisig, _singleUint(1));
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.rescueTokens(address(1), acc.multisig, 1);
        vm.stopPrank();
    }

    function test_fundsAdmin_cannot_create_or_pause_sales() public {
        vm.startPrank(acc.salesManagerFundsAdmin);
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.createSale(address(1), _single(address(2)), acc.multisig, 1, 1e8, 100, 200);
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.setEmergencyPause();
        vm.stopPrank();
    }

    function test_fiatOrder_cannot_withdraw_or_update_sales() public {
        vm.startPrank(acc.fiatOrderSigner);
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.withdrawFunds(_single(address(1)), acc.multisig, _singleUint(1));
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.updateSalePriceUsdPerShare(0, 1e8);
        vm.stopPrank();
    }

    function test_tokenMinter_cannot_freeze() public {
        vm.prank(acc.factoryShareDeployer);
        Token token = p.createShare(acc.multisig, acc.identityRegistryAgent, "RMX", "RMX", 100);
        vm.prank(acc.user1);
        vm.expectRevert(ITokenController.NotAuthorized.selector);
        p.tokenController.setFrozen(address(token), acc.buyer, true);
    }

    function test_tokenFreezer_cannot_mint() public {
        vm.prank(acc.factoryShareDeployer);
        Token token = p.createShare(acc.multisig, acc.identityRegistryAgent, "RMF", "RMF", 100);
        vm.prank(acc.user2);
        vm.expectRevert(ITokenController.NotAuthorized.selector);
        p.tokenController.mint(address(token), acc.buyer, 1);
    }

    function test_shareDeployer_cannot_upgrade_factory() public {
        Factory newImpl = new Factory();
        vm.prank(acc.factoryShareDeployer);
        vm.expectRevert(IFactory.NotAuthorized.selector);
        IUUPSUpgradeableLike(address(p.factory)).upgradeToAndCall(address(newImpl), "");
    }

    function test_shareDeployer_cannot_deploy_custom_share_suite() public {
        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: acc.multisig,
            name: "Custom",
            symbol: "CST",
            decimals: 0,
            irs: address(p.identityRegistryStorage),
            ONCHAINID: address(0),
            irAgents: _single(acc.identityRegistryAgent),
            tokenAgents: _single(acc.multisig),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0)
        });

        ITREXFactory.ClaimDetails memory claimDetails = ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });

        vm.prank(acc.factoryShareDeployer);
        vm.expectRevert(IFactory.NotAuthorized.selector);
        p.factory.deployShareSuite("DEPLOYER_BYPASS", tokenDetails, claimDetails);
    }

    function test_upgrader_cannot_deploy_share_without_shareDeployer_role() public {
        vm.prank(acc.multisig);
        vm.expectRevert(IFactory.NotAuthorized.selector);
        p.factory
            .createShare(
                IFactory.CreateShareParams({
                    name: "UPG",
                    symbol: "UPG",
                    decimals: 0,
                    owner: acc.multisig,
                    tokenAgents: new address[](0),
                    irAgents: _single(acc.identityRegistryAgent),
                    irs: address(p.identityRegistryStorage),
                    claimTopics: new uint256[](0),
                    issuers: new address[](0),
                    issuerClaims: new uint256[][](0),
                    maxSupply: 1000
                })
            );
    }

    function _singleUint(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }
}
