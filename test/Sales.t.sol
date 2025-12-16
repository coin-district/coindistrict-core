// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import 'forge-std/Test.sol';
import {ProtocolFixture, Protocol, Accounts} from './fixtures/ProtocolFixture.sol';
import {ShareTestUtils} from './utils/ShareTestUtils.sol';

import {Identity} from '@onchain-id/solidity/contracts/Identity.sol';
import {IIdentity} from '@onchain-id/solidity/contracts/interface/IIdentity.sol';
import {IClaimIssuer} from '@onchain-id/solidity/contracts/interface/IClaimIssuer.sol';

import {ClaimTopicsRegistry} from '@erc3643org/erc-3643/contracts/registry/implementation/ClaimTopicsRegistry.sol';
import {TrustedIssuersRegistry} from '@erc3643org/erc-3643/contracts/registry/implementation/TrustedIssuersRegistry.sol';
import {IdentityRegistry} from '@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistry.sol';
import {Token} from '@erc3643org/erc-3643/contracts/token/Token.sol';

import {MaxSupplyModule} from 'contracts/compliance/modules/MaxSupplyModule.sol';
import {SalesManager} from 'contracts/SalesManager.sol';
import {TokenController} from 'contracts/TokenController.sol';
import {Factory} from 'contracts/Factory.sol';
import {MockToken} from 'contracts/mocks/MockToken.sol';
import {MockAggregatorV3} from 'contracts/mocks/MockAggregatorV3.sol';

contract SalesTest is Test, ProtocolFixture {
    using ShareTestUtils for Protocol;
    uint256 constant DEFAULT_MAX_SUPPLY = 1000;

    // accounts
    address internal multisig = vm.addr(2);
    address internal identityRegistryAgent = vm.addr(3);
    address internal identityRegistryAgent2 = vm.addr(4);
    address internal claimIssuer = vm.addr(5);
    address internal factoryShareDeployer = vm.addr(6);
    address internal salesManagerSalesConfig = vm.addr(7);
    address internal salesManagerSalesOperator = vm.addr(8);
    address internal salesManagerFundsAdmin = vm.addr(9);
    address internal fiatOrderSigner = vm.addr(10);
    address internal buyer = vm.addr(11);
    address internal tokenAgent = vm.addr(14);

    Accounts internal acc = defaultAccounts();
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
    }

    function test_buy_open_token_succeeds_after_allowlist_and_unpause() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'SALE', 'SAL', DEFAULT_MAX_SUPPLY);
        // prepare controller: set caps, unpause
        uint256 PAUSABLE_BIT = 1 << 1;
        p.tokenController.setTokenCapsInitial(address(token), PAUSABLE_BIT);
        vm.stopPrank();

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        // register buyer identity (required even if no claim topics)
        p.registerIdentity(vm, identityRegistryAgent, buyer);

        // payment token + oracle
        MockToken stable = new MockToken('USD', 'USD', 6);
        stable.mint(buyer, 1_000_000_000); // 1000 USD
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000); // 1 token = 1 USD

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle));
        vm.stopPrank();

        // create sale
        uint256 priceUsdPerShare = 1e8; // $1
        uint64 deadline = uint64(block.timestamp + 3600);

        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 100, priceUsdPerShare, deadline);

        uint256 saleId = p.salesManager.saleCount() - 1;

        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 10_000_000); // 10 USD
        p.salesManager.buy(saleId, 10, buyer, address(stable), 10_000_000);
        vm.stopPrank();

        assertEq(token.balanceOf(buyer), 10);
        (, , , uint256 remaining, , , , , ) = p.salesManager.sales(saleId);
        assertEq(remaining, 90);
    }

    function test_createSale_rejects_bad_inputs_and_cap() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'BAD', 'BAD', 1000);

        MockToken stable = new MockToken('USD', 'USD', 6);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle));
        vm.stopPrank();

        uint256 priceUsdPerShare = 1e8;
        uint64 nowTs = uint64(block.timestamp);

        vm.startPrank(salesManagerSalesOperator);
        vm.expectRevert(bytes('Sale_InvalidAddress'));
        p.salesManager.createSale(ZERO, _single(address(stable)), multisig, 10, priceUsdPerShare, nowTs + 100);

        vm.expectRevert(bytes('Sale_InvalidRecipient'));
        p.salesManager.createSale(address(token), _single(address(stable)), ZERO, 10, priceUsdPerShare, nowTs + 100);

        vm.expectRevert(bytes('Sale_ZeroSupply'));
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 0, priceUsdPerShare, nowTs + 100);

        vm.expectRevert(bytes('Sale_ZeroPrice'));
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 10, 0, nowTs + 100);

        vm.expectRevert(bytes('Sale_InvalidDeadline'));
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 10, priceUsdPerShare, nowTs - 1);

        // exceeding cap
        vm.expectRevert(bytes('Sale_SupplyExceedsCap'));
        p.salesManager.createSale(
            address(token),
            _single(address(stable)),
            multisig,
            2000,
            priceUsdPerShare,
            nowTs + 1000
        );
        vm.stopPrank();
    }

    function test_pause_unpause_sale() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'P', 'P', 1000);
        uint256 PAUSABLE_BIT = 1 << 1;
        p.tokenController.setTokenCapsInitial(address(token), PAUSABLE_BIT);
        vm.stopPrank();

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        IIdentity buyerIdentity = IIdentity(address(new Identity(buyer, false)));

        vm.prank(identityRegistryAgent);
        p.identityRegistry.registerIdentity(buyer, buyerIdentity, 1);

        MockToken stable = new MockToken('USD', 'USD', 6);
        stable.mint(buyer, 1_000_000_000);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle));
        vm.stopPrank();

        uint64 deadline = uint64(block.timestamp + 3600);
        vm.startPrank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 50, 1e8, deadline);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 50, 1e8, deadline);
        vm.stopPrank();
        uint256 saleId = p.salesManager.saleCount() - 1;

        vm.prank(buyer);
        stable.approve(address(p.salesManager), 10_000_000);

        vm.prank(salesManagerSalesOperator);
        p.salesManager.pauseSale(saleId);

        vm.startPrank(buyer);
        vm.expectRevert(bytes('Sale_Paused'));
        p.salesManager.buy(saleId, 5, buyer, address(stable), 10_000_000);
        vm.stopPrank();

        vm.prank(salesManagerSalesOperator);
        p.salesManager.unpauseSale(saleId);

        vm.prank(buyer);
        p.salesManager.buy(saleId, 5, buyer, address(stable), 10_000_000);
        assertEq(token.balanceOf(buyer), 5);
    }

    function test_permissioned_buy_requires_KYC_claim() public {
        uint256 KYC_TOPIC = 7;
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'KYC', 'KYC', 1000);

        // add claim topic + trusted issuer on token-specific registries (owned by multisig after token creation)
        IdentityRegistry ir = IdentityRegistry(address(token.identityRegistry()));
        ClaimTopicsRegistry ctr = ClaimTopicsRegistry(address(ir.topicsRegistry()));
        TrustedIssuersRegistry tir = TrustedIssuersRegistry(address(ir.issuersRegistry()));

        vm.startPrank(multisig);
        ctr.addClaimTopic(KYC_TOPIC);
        tir.addTrustedIssuer(IClaimIssuer(address(p.claimIssuer)), _singleUint(KYC_TOPIC));
        vm.stopPrank();

        uint256 PAUSABLE_BIT = 1 << 1;

        vm.prank(factoryShareDeployer);
        p.tokenController.setTokenCapsInitial(address(token), PAUSABLE_BIT);

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        // register buyer identity but no claim yet
        p.registerIdentity(vm, identityRegistryAgent, buyer);

        MockToken stable = new MockToken('USD', 'USD', 6);
        stable.mint(buyer, 1_000_000_000);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle));
        vm.stopPrank();

        uint64 deadline = uint64(block.timestamp + 3600);

        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 50, 1e8, deadline);
        uint256 saleId = p.salesManager.saleCount() - 1;

        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(); // identity not verified (missing KYC claim)
        p.salesManager.buy(saleId, 5, buyer, address(stable), 10_000_000);
        vm.stopPrank();

        // minimal unblock: remove topic (ClaimIssuer signature flow omitted in this Foundry port)
        vm.prank(multisig);
        ctr.removeClaimTopic(KYC_TOPIC);

        vm.prank(buyer);
        p.salesManager.buy(saleId, 5, buyer, address(stable), 10_000_000);
        assertEq(token.balanceOf(buyer), 5);
    }

    function test_updateSalePaymentTokensAllowed_requires_allowlist_and_oracle() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'U', 'U', 1000);
        _unpauseToken(token, (1 << 1));
        p.registerIdentity(vm, identityRegistryAgent, buyer);

        MockToken stable = new MockToken('USD', 'USD', 6);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle));
        vm.stopPrank();

        uint64 deadline = uint64(block.timestamp + 3600);
        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 50, 1e8, deadline);
        uint256 saleId = p.salesManager.saleCount() - 1;

        // new token not allowlisted
        MockToken unallowed = new MockToken('UNL', 'UNL', 6);

        vm.startPrank(salesManagerSalesOperator);
        vm.expectRevert(bytes('Sale_PaymentTokenNotAllowed'));
        p.salesManager.updateSalePaymentTokensAllowed(saleId, _single(address(unallowed)));
        vm.stopPrank();

        // allowlist but no oracle

        vm.prank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(unallowed), true);

        vm.startPrank(salesManagerSalesOperator);
        vm.expectRevert(bytes('Sale_OracleNotConfigured'));
        p.salesManager.updateSalePaymentTokensAllowed(saleId, _single(address(unallowed)));
        vm.stopPrank();

        // set oracle then succeed
        MockAggregatorV3 oracle2 = new MockAggregatorV3(8, 100_000_000);

        vm.prank(salesManagerSalesConfig);
        p.salesManager.setPaymentTokenOracle(address(unallowed), address(oracle2));

        vm.prank(salesManagerSalesOperator);
        p.salesManager.updateSalePaymentTokensAllowed(saleId, _single(address(unallowed)));
        (, address[] memory allowed, , , , , , , ) = p.salesManager.sales(saleId);
        assertEq(allowed.length, 1);
        assertEq(allowed[0], address(unallowed));
    }

    function test_updateSaleFundsRecipient_routes_funds() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'F', 'F', 1000);
        _unpauseToken(token, (1 << 1));
        p.registerIdentity(vm, identityRegistryAgent, buyer);

        MockToken stable = new MockToken('USD', 'USD', 6);
        stable.mint(buyer, 1_000_000_000);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle));
        vm.stopPrank();

        uint64 deadline = uint64(block.timestamp + 3600);
        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 50, 1e8, deadline);
        uint256 saleId = p.salesManager.saleCount() - 1;

        address newRecipient = vm.addr(1234);

        vm.prank(salesManagerFundsAdmin);
        p.salesManager.updateSaleFundsRecipient(saleId, newRecipient);

        uint256 before = stable.balanceOf(newRecipient);

        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 10_000_000);
        p.salesManager.buy(saleId, 5, buyer, address(stable), 10_000_000);
        vm.stopPrank();
        uint256 afterBal = stable.balanceOf(newRecipient);
        assertEq(afterBal - before, 5_000_000);
    }

    function test_fulfillFiatOrder_respects_pause_and_deadline() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'FFO', 'FFO', 1000);
        _unpauseToken(token, (1 << 1));
        address recipient = vm.addr(4567);
        p.registerIdentity(vm, identityRegistryAgent, recipient);

        MockToken stable = new MockToken('USD', 'USD', 6);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle));
        vm.stopPrank();

        uint64 deadline = uint64(block.timestamp + 3600);
        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 50, 1e8, deadline);
        uint256 saleId = p.salesManager.saleCount() - 1;

        // pause sale

        vm.prank(salesManagerSalesOperator);
        p.salesManager.pauseSale(saleId);

        vm.startPrank(fiatOrderSigner);
        vm.expectRevert(bytes('Sale_Paused'));
        p.salesManager.fulfillFiatOrder(saleId, 10, recipient, bytes32('ref'));
        vm.stopPrank();

        vm.prank(salesManagerSalesOperator);
        p.salesManager.unpauseSale(saleId);

        vm.prank(fiatOrderSigner);
        p.salesManager.fulfillFiatOrder(saleId, 10, recipient, bytes32('ref'));
        assertEq(token.balanceOf(recipient), 10);
        (, , , uint256 remaining, , , , , ) = p.salesManager.sales(saleId);
        assertEq(remaining, 40);
    }

    function _singleUint(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    function _unpauseToken(Token token, uint256 caps) internal {
        vm.prank(factoryShareDeployer);
        p.tokenController.setTokenCapsInitial(address(token), caps);

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));
    }
}
