// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from 'forge-std/Test.sol';
import {ProtocolFixture, Protocol, Accounts} from './fixtures/ProtocolFixture.sol';
import {ShareTestUtils} from './utils/ShareTestUtils.sol';

import {Identity} from '@onchain-id/solidity/contracts/Identity.sol';
import {IIdentity} from '@onchain-id/solidity/contracts/interface/IIdentity.sol';
import {IClaimIssuer} from '@onchain-id/solidity/contracts/interface/IClaimIssuer.sol';

import {ClaimTopicsRegistry} from '@erc3643org/erc-3643/contracts/registry/implementation/ClaimTopicsRegistry.sol';
import {TrustedIssuersRegistry} from '@erc3643org/erc-3643/contracts/registry/implementation/TrustedIssuersRegistry.sol';
import {IdentityRegistry} from '@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistry.sol';
import {Token} from '@erc3643org/erc-3643/contracts/token/Token.sol';

import {MockToken} from 'contracts/mocks/MockToken.sol';
import {MockFeeOnTransferToken} from 'contracts/mocks/MockFeeOnTransferToken.sol';
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

    function test_buy_reverts_for_fee_on_transfer_payment_token() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'FOT', 'FOT', DEFAULT_MAX_SUPPLY);
        // prepare controller: set caps, unpause
        uint256 PAUSABLE_BIT = 1 << 1;
        p.tokenController.setTokenCapsInitial(address(token), PAUSABLE_BIT);
        vm.stopPrank();

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        // register buyer identity (required even if no claim topics)
        p.registerIdentity(vm, identityRegistryAgent, buyer);

        // fee-on-transfer payment token + oracle
        address feeCollector = vm.addr(4242);
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken('FOTUSD', 'FOTUSD', 6, 100, feeCollector); // 1% fee
        fot.mint(buyer, 1_000_000_000); // 1000 tokens
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000); // 1 token = 1 USD

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(fot), true);
        p.salesManager.setPaymentTokenOracle(address(fot), address(oracle));
        vm.stopPrank();

        // create sale
        uint256 priceUsdPerShare = 1e8; // $1
        uint64 deadline = uint64(block.timestamp + 3600);

        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(fot)), multisig, 100, priceUsdPerShare, deadline);

        uint256 saleId = p.salesManager.saleCount() - 1;

        uint256 buyerBefore = fot.balanceOf(buyer);
        uint256 feeCollectorBefore = fot.balanceOf(feeCollector);
        uint256 treasuryBefore = fot.balanceOf(multisig);

        vm.startPrank(buyer);
        fot.approve(address(p.salesManager), 10_000_000); // 10 tokens max
        vm.expectRevert(bytes('Sale_TransferAmountMismatch'));
        p.salesManager.buy(saleId, 10, buyer, address(fot), 10_000_000);
        vm.stopPrank();

        // Whole tx reverted: balances unchanged, no fee collected
        assertEq(fot.balanceOf(buyer), buyerBefore);
        assertEq(fot.balanceOf(feeCollector), feeCollectorBefore);
        assertEq(fot.balanceOf(multisig), treasuryBefore);
        assertEq(token.balanceOf(buyer), 0);
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
        p.salesManager.fulfillFiatOrder(saleId, 10, recipient, keccak256(bytes('ref')));
        vm.stopPrank();

        vm.prank(salesManagerSalesOperator);
        p.salesManager.unpauseSale(saleId);

        vm.prank(fiatOrderSigner);
        p.salesManager.fulfillFiatOrder(saleId, 10, recipient, keccak256(bytes('ref')));
        assertEq(token.balanceOf(recipient), 10);
        (, , , uint256 remaining, , , , , ) = p.salesManager.sales(saleId);
        assertEq(remaining, 40);
    }

    function test_rescueTokens_rejects_allowed_payment_tokens() public {
        // Setup: Create an allowed payment token
        MockToken allowedToken = new MockToken('USDC', 'USDC', 6);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(allowedToken), true);
        p.salesManager.setPaymentTokenOracle(address(allowedToken), address(oracle));
        vm.stopPrank();

        // Send some tokens to SalesManager (simulating accidental transfer)
        allowedToken.mint(address(p.salesManager), 100_000_000); // 100 USDC
        address recipient = vm.addr(9999);

        // Attempt to rescue allowed payment token - should fail
        vm.startPrank(salesManagerFundsAdmin);
        vm.expectRevert(bytes('Rescue_UseWithdrawFundsForPaymentTokens'));
        p.salesManager.rescueTokens(address(allowedToken), recipient, 50_000_000);
        vm.stopPrank();

        // Verify tokens are still in SalesManager
        assertEq(allowedToken.balanceOf(address(p.salesManager)), 100_000_000);
        assertEq(allowedToken.balanceOf(recipient), 0);

        // Use withdrawFunds instead - should succeed
        vm.prank(salesManagerFundsAdmin);
        p.salesManager.withdrawFunds(_single(address(allowedToken)), recipient, _singleUint(50_000_000));

        // Verify tokens were withdrawn
        assertEq(allowedToken.balanceOf(address(p.salesManager)), 50_000_000);
        assertEq(allowedToken.balanceOf(recipient), 50_000_000);
    }

    function test_rescueTokens_succeeds_for_non_allowed_tokens() public {
        // Create a non-allowed token (e.g., accidentally sent to contract)
        MockToken randomToken = new MockToken('RANDOM', 'RND', 18);
        randomToken.mint(address(p.salesManager), 1_000_000_000_000_000_000); // 1 token
        address recipient = vm.addr(8888);

        // Rescue should succeed for non-allowed tokens
        vm.prank(salesManagerFundsAdmin);
        p.salesManager.rescueTokens(address(randomToken), recipient, 500_000_000_000_000_000);

        // Verify tokens were rescued
        assertEq(randomToken.balanceOf(address(p.salesManager)), 500_000_000_000_000_000);
        assertEq(randomToken.balanceOf(recipient), 500_000_000_000_000_000);
    }

    function test_rescueTokens_rejects_zero_address() public {
        MockToken randomToken = new MockToken('RANDOM', 'RND', 18);
        randomToken.mint(address(p.salesManager), 1_000_000_000_000_000_000);

        vm.startPrank(salesManagerFundsAdmin);
        vm.expectRevert(bytes('Rescue_InvalidRecipient'));
        p.salesManager.rescueTokens(address(randomToken), ZERO, 100_000_000_000_000_000);
        vm.stopPrank();
    }

    function test_withdrawFunds_succeeds_for_allowed_payment_tokens() public {
        // Setup: Create and allowlist payment tokens
        MockToken usdc = new MockToken('USDC', 'USDC', 6);
        MockToken usdt = new MockToken('USDT', 'USDT', 6);
        MockAggregatorV3 oracle1 = new MockAggregatorV3(8, 100_000_000);
        MockAggregatorV3 oracle2 = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(usdc), true);
        p.salesManager.setPaymentTokenOracle(address(usdc), address(oracle1));
        p.salesManager.setAllowedPaymentToken(address(usdt), true);
        p.salesManager.setPaymentTokenOracle(address(usdt), address(oracle2));
        vm.stopPrank();

        // Send tokens to SalesManager (simulating funds from sales)
        usdc.mint(address(p.salesManager), 500_000_000); // 500 USDC
        usdt.mint(address(p.salesManager), 300_000_000); // 300 USDT
        address recipient = vm.addr(7777);

        // Withdraw single token
        vm.prank(salesManagerFundsAdmin);
        p.salesManager.withdrawFunds(_single(address(usdc)), recipient, _singleUint(200_000_000));

        assertEq(usdc.balanceOf(address(p.salesManager)), 300_000_000);
        assertEq(usdc.balanceOf(recipient), 200_000_000);

        // Withdraw multiple tokens in one call
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(usdt);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100_000_000;
        amounts[1] = 150_000_000;

        vm.prank(salesManagerFundsAdmin);
        p.salesManager.withdrawFunds(tokens, recipient, amounts);

        assertEq(usdc.balanceOf(address(p.salesManager)), 200_000_000);
        assertEq(usdt.balanceOf(address(p.salesManager)), 150_000_000);
        assertEq(usdc.balanceOf(recipient), 300_000_000);
        assertEq(usdt.balanceOf(recipient), 150_000_000);
    }

    function test_withdrawFunds_rejects_non_allowed_tokens() public {
        MockToken unallowedToken = new MockToken('UNL', 'UNL', 18);
        unallowedToken.mint(address(p.salesManager), 1_000_000_000_000_000_000);
        address recipient = vm.addr(6666);

        vm.startPrank(salesManagerFundsAdmin);
        vm.expectRevert(bytes('Sale_PaymentTokenNotAllowed'));
        p.salesManager.withdrawFunds(_single(address(unallowedToken)), recipient, _singleUint(500_000_000_000_000_000));
        vm.stopPrank();

        // Verify tokens are still in SalesManager
        assertEq(unallowedToken.balanceOf(address(p.salesManager)), 1_000_000_000_000_000_000);
        assertEq(unallowedToken.balanceOf(recipient), 0);
    }

    function test_withdrawFunds_rejects_zero_address() public {
        MockToken usdc = new MockToken('USDC', 'USDC', 6);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(usdc), true);
        p.salesManager.setPaymentTokenOracle(address(usdc), address(oracle));
        vm.stopPrank();

        usdc.mint(address(p.salesManager), 100_000_000);

        vm.startPrank(salesManagerFundsAdmin);
        vm.expectRevert(bytes('Rescue_InvalidRecipient'));
        p.salesManager.withdrawFunds(_single(address(usdc)), ZERO, _singleUint(50_000_000));
        vm.stopPrank();
    }

    function test_withdrawFunds_rejects_length_mismatch() public {
        MockToken usdc = new MockToken('USDC', 'USDC', 6);
        MockToken usdt = new MockToken('USDT', 'USDT', 6);
        MockAggregatorV3 oracle1 = new MockAggregatorV3(8, 100_000_000);
        MockAggregatorV3 oracle2 = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(usdc), true);
        p.salesManager.setPaymentTokenOracle(address(usdc), address(oracle1));
        p.salesManager.setAllowedPaymentToken(address(usdt), true);
        p.salesManager.setPaymentTokenOracle(address(usdt), address(oracle2));
        vm.stopPrank();

        usdc.mint(address(p.salesManager), 100_000_000);
        usdt.mint(address(p.salesManager), 100_000_000);
        address recipient = vm.addr(5555);

        // Test: tokens.length != amounts.length
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(usdt);
        uint256[] memory amounts = new uint256[](1); // Mismatch: only 1 amount for 2 tokens
        amounts[0] = 50_000_000;

        vm.startPrank(salesManagerFundsAdmin);
        vm.expectRevert(bytes('Sale_LengthMismatch'));
        p.salesManager.withdrawFunds(tokens, recipient, amounts);
        vm.stopPrank();

        // Test: empty arrays
        address[] memory emptyTokens = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        vm.prank(salesManagerFundsAdmin);
        p.salesManager.withdrawFunds(emptyTokens, recipient, emptyAmounts); // Should succeed (no-op)
    }

    function test_withdrawFunds_partial_allowed_token_mix_reverts() public {
        // Setup: One allowed, one not allowed
        MockToken allowedToken = new MockToken('USDC', 'USDC', 6);
        MockToken unallowedToken = new MockToken('UNL', 'UNL', 18);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(allowedToken), true);
        p.salesManager.setPaymentTokenOracle(address(allowedToken), address(oracle));
        vm.stopPrank();

        allowedToken.mint(address(p.salesManager), 100_000_000);
        unallowedToken.mint(address(p.salesManager), 1_000_000_000_000_000_000);
        address recipient = vm.addr(4444);

        // Try to withdraw both - should fail on the unallowed token
        address[] memory tokens = new address[](2);
        tokens[0] = address(allowedToken);
        tokens[1] = address(unallowedToken);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50_000_000;
        amounts[1] = 500_000_000_000_000_000;

        vm.startPrank(salesManagerFundsAdmin);
        vm.expectRevert(bytes('Sale_PaymentTokenNotAllowed'));
        p.salesManager.withdrawFunds(tokens, recipient, amounts);
        vm.stopPrank();

        // Verify no tokens were transferred
        assertEq(allowedToken.balanceOf(address(p.salesManager)), 100_000_000);
        assertEq(unallowedToken.balanceOf(address(p.salesManager)), 1_000_000_000_000_000_000);
        assertEq(allowedToken.balanceOf(recipient), 0);
        assertEq(unallowedToken.balanceOf(recipient), 0);
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
