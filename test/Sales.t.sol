// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Protocol, IUUPSUpgradeableLike} from "./fixtures/ProtocolFixture.sol";
import {ShareTestUtils} from "./utils/ShareTestUtils.sol";
import {SalesTestHelpers, BasicSaleCtx} from "./utils/SalesTestHelpers.sol";

import {IIdentity} from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import {IClaimIssuer} from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";

import {ClaimTopicsRegistry} from "@erc3643org/erc-3643/contracts/registry/implementation/ClaimTopicsRegistry.sol";
import {
    TrustedIssuersRegistry
} from "@erc3643org/erc-3643/contracts/registry/implementation/TrustedIssuersRegistry.sol";
import {IdentityRegistry} from "@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistry.sol";
import {Token} from "@erc3643org/erc-3643/contracts/token/Token.sol";

import {MockToken} from "contracts/mocks/MockToken.sol";
import {MockFeeOnTransferToken} from "contracts/mocks/MockFeeOnTransferToken.sol";
import {MockAggregatorV3} from "contracts/mocks/MockAggregatorV3.sol";
import {MaliciousToken} from "./mocks/ReentrantBuyer.sol";
import {IModularCompliance} from "@erc3643org/erc-3643/contracts/compliance/modular/IModularCompliance.sol";
import {SalesManager} from "contracts/SalesManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MaxSupplyModule} from "contracts/compliance/modules/MaxSupplyModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract SalesTest is SalesTestHelpers {
    using ShareTestUtils for Protocol;

    event PaymentTokenOracleSet(
        address indexed paymentToken, address aggregator, uint256 maxDelay, uint256 maxPrice1e8
    );

    // Initialization

    function test_SalesManager_implementation_disables_initializers() public {
        SalesManager impl = new SalesManager();
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        impl.initialize(address(p.governance));
    }

    function test_SalesManager_initialize_rejects_zero_governance() public {
        SalesManager impl = new SalesManager();
        SalesManager proxy = SalesManager(payable(address(new ERC1967Proxy(address(impl), ""))));
        vm.expectRevert(bytes("SalesManager_InvalidGovernance"));
        proxy.initialize(address(0));
    }

    function test_SalesManager_initialize_reverts_on_double_init() public {
        SalesManager impl = new SalesManager();
        SalesManager proxy = SalesManager(payable(address(new ERC1967Proxy(address(impl), ""))));
        proxy.initialize(address(p.governance));
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        proxy.initialize(address(p.governance));
    }

    // Upgrades / proxy

    function test_SalesManager_UpgradeRequiresRole() public {
        address attacker = vm.addr(77);
        SalesManager newImpl = new SalesManager();
        vm.prank(attacker);
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        p.salesManager.upgradeTo(address(newImpl));
    }

    function test_SalesManager_UpgradeWithRolePreservesState() public {
        MockToken stable = new MockToken("USD", "USD", 6);
        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        vm.stopPrank();
        assertTrue(p.salesManager.allowedPaymentToken(address(stable)));

        SalesManager newImpl = new SalesManager();
        vm.prank(multisig);
        p.salesManager.upgradeTo(address(newImpl));

        assertTrue(p.salesManager.allowedPaymentToken(address(stable)));
    }

    function test_SalesManager_upgradeToAndCall_unauthorized_reverts() public {
        SalesManager newImpl = new SalesManager();
        vm.prank(vm.addr(99));
        vm.expectRevert(bytes("SalesManager_NotAuthorized"));
        IUUPSUpgradeableLike(address(p.salesManager)).upgradeToAndCall(address(newImpl), "");
    }

    function test_SalesManager_upgradeToAndCall_preserves_storage() public {
        MockToken stable = new MockToken("UT", "UT", 6);
        vm.prank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);

        SalesManager newImpl = new SalesManager();
        vm.prank(multisig);
        p.salesManager.upgradeTo(address(newImpl));
        assertTrue(p.salesManager.allowedPaymentToken(address(stable)));
    }

    // createSale

    function test_createSale_rejects_bad_inputs_and_cap() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "BAD", "BAD", 1000);

        MockToken stable = new MockToken("USD", "USD", 6);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        uint256 priceUsdPerShare = 1e8;
        uint64 nowTs = uint64(block.timestamp);

        vm.startPrank(salesManagerSalesOperator);
        vm.expectRevert(bytes("Sale_InvalidAddress"));
        p.salesManager
            .createSale(ZERO, _single(address(stable)), multisig, 10, priceUsdPerShare, nowTs + 100, nowTs + 200);

        vm.expectRevert(bytes("Sale_InvalidRecipient"));
        p.salesManager
            .createSale(address(token), _single(address(stable)), ZERO, 10, priceUsdPerShare, nowTs + 100, nowTs + 200);

        vm.expectRevert(bytes("Sale_ZeroSupply"));
        p.salesManager
            .createSale(
                address(token), _single(address(stable)), multisig, 0, priceUsdPerShare, nowTs + 100, nowTs + 200
            );

        vm.expectRevert(bytes("Sale_ZeroPrice"));
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 10, 0, nowTs + 100, nowTs + 200);

        vm.expectRevert(bytes("Sale_InvalidStart"));
        p.salesManager
            .createSale(address(token), _single(address(stable)), multisig, 10, priceUsdPerShare, nowTs, nowTs + 200);

        vm.expectRevert(bytes("Sale_InvalidStart"));
        p.salesManager
            .createSale(
                address(token), _single(address(stable)), multisig, 10, priceUsdPerShare, nowTs - 1, nowTs + 200
            );

        vm.expectRevert(bytes("Sale_InvalidDeadline"));
        p.salesManager
            .createSale(
                address(token), _single(address(stable)), multisig, 10, priceUsdPerShare, nowTs + 100, nowTs + 100
            );

        vm.expectRevert(bytes("Sale_InvalidDeadline"));
        p.salesManager
            .createSale(
                address(token), _single(address(stable)), multisig, 10, priceUsdPerShare, nowTs + 100, nowTs + 50
            );

        // exceeding cap
        vm.expectRevert(bytes("Sale_SupplyExceedsCap"));
        p.salesManager
            .createSale(
                address(token), _single(address(stable)), multisig, 2000, priceUsdPerShare, nowTs + 100, nowTs + 1000
            );
        vm.stopPrank();
    }

    function test_createSale_succeeds_when_maxSupply_zero_no_cap_check() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "UNCAP", "UNC", DEFAULT_MAX_SUPPLY);
        vm.stopPrank();
        address compliance = address(token.compliance());
        IModularCompliance mc = IModularCompliance(compliance);
        MaxSupplyModule module = MaxSupplyModule(p.maxSupplyModule);
        bytes memory setZero = abi.encodeWithSignature("setMaxSupply(uint256)", 0);
        vm.prank(multisig);
        mc.callModuleFunction(setZero, address(module));

        _unpauseToken(token, p.tokenController.PAUSABLE_BIT());
        p.registerIdentity(vm, identityRegistryAgent, buyer);

        MockToken stable = new MockToken("USD", "USD", 6);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);
        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);
        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 50_000, 1e8, start, deadline);
        assertEq(p.salesManager.getSaleRemainingSupply(p.salesManager.saleCount() - 1), 50_000);
    }

    // buy: happy path and fuzz amounts

    function test_buy_open_token_succeeds_after_allowlist_and_unpause() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "SALE", "SAL", DEFAULT_MAX_SUPPLY);

        // prepare controller: set caps, unpause
        p.tokenController.setTokenCapsInitial(address(token), p.tokenController.PAUSABLE_BIT());
        vm.stopPrank();

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        // register buyer identity (required even if no claim topics)
        p.registerIdentity(vm, identityRegistryAgent, buyer);

        // payment token + oracle
        MockToken stable = new MockToken("USD", "USD", 6);
        stable.mint(buyer, 1_000_000_000); // 1000 USD
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000); // 1 token = 1 USD

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        // create sale
        uint256 priceUsdPerShare = 1e8; // $1
        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);

        vm.prank(salesManagerSalesOperator);
        p.salesManager
            .createSale(address(token), _single(address(stable)), multisig, 100, priceUsdPerShare, start, deadline);

        uint256 saleId = p.salesManager.saleCount() - 1;

        // Warp to start time
        vm.warp(start + 1);

        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 10_000_000); // 10 USD
        p.salesManager.buy(saleId, 10, buyer, address(stable), 10_000_000);
        vm.stopPrank();

        assertEq(token.balanceOf(buyer), 10);
        (,,, uint256 remaining,,,,,,) = p.salesManager.getSale(saleId);
        assertEq(remaining, 90);
    }

    function test_buy_with_aggregator_decimals_18_scales_down() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "D18", "D18", DEFAULT_MAX_SUPPLY);
        p.tokenController.setTokenCapsInitial(address(token), p.tokenController.PAUSABLE_BIT());
        vm.stopPrank();
        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));
        p.registerIdentity(vm, identityRegistryAgent, buyer);

        MockToken stable = new MockToken("USD", "USD", 6);
        stable.mint(buyer, 1_000_000_000);
        MockAggregatorV3 oracle = new MockAggregatorV3(18, int256(1e18));

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);
        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 100, 1e8, start, deadline);
        uint256 saleId = p.salesManager.saleCount() - 1;
        vm.warp(start + 1);

        uint256 usdcBefore = stable.balanceOf(multisig);
        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 100_000_000);
        p.salesManager.buy(saleId, 10, buyer, address(stable), 100_000_000);
        vm.stopPrank();
        assertEq(stable.balanceOf(multisig) - usdcBefore, 10_000_000);
        assertEq(token.balanceOf(buyer), 10);
    }

    function test_buy_with_aggregator_decimals_6_scales_up() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "D6", "D6", DEFAULT_MAX_SUPPLY);
        p.tokenController.setTokenCapsInitial(address(token), p.tokenController.PAUSABLE_BIT());
        vm.stopPrank();
        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));
        p.registerIdentity(vm, identityRegistryAgent, buyer);

        MockToken stable = new MockToken("USD", "USD", 6);
        stable.mint(buyer, 1_000_000_000);
        MockAggregatorV3 oracle = new MockAggregatorV3(6, int256(1_000_000));

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);
        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 100, 1e8, start, deadline);
        uint256 saleId = p.salesManager.saleCount() - 1;
        vm.warp(start + 1);

        uint256 usdcBefore = stable.balanceOf(multisig);
        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 100_000_000);
        p.salesManager.buy(saleId, 10, buyer, address(stable), 100_000_000);
        vm.stopPrank();
        assertEq(stable.balanceOf(multisig) - usdcBefore, 10_000_000);
        assertEq(token.balanceOf(buyer), 10);
    }

    function testFuzz_buy_charges_expected_cost(uint256 amount, uint256 oracleAns) public {
        BasicSaleCtx memory ctx = _setupBasicSale("FZB", "FZB", 1000, 1e8);
        amount = bound(amount, 1, 1000);
        oracleAns = bound(oracleAns, 1e6, 1e11);
        ctx.oracle.updatePrice(int256(oracleAns));
        vm.warp(ctx.start + 1);

        uint256 expected = _expectedCost(amount, 1e8, 0, oracleAns);
        ctx.stable.mint(buyer, expected);
        uint256 buyerSharesBefore = ctx.token.balanceOf(buyer);
        uint256 treasuryBefore = ctx.stable.balanceOf(multisig);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), expected);
        p.salesManager.buy(ctx.saleId, amount, buyer, address(ctx.stable), expected);
        vm.stopPrank();

        assertEq(ctx.token.balanceOf(buyer) - buyerSharesBefore, amount, "shares minted");
        assertEq(ctx.stable.balanceOf(multisig) - treasuryBefore, expected, "treasury received");
    }

    function testFuzz_buy_varied_share_decimals(uint8 shareDecimals, uint256 amount) public {
        shareDecimals = uint8(bound(shareDecimals, 0, 18));
        uint256 maxSupply = 1_000_000 * (10 ** uint256(shareDecimals));
        BasicSaleCtx memory ctx = _setupBasicSaleWithDecimals("FZV", "FZV", shareDecimals, maxSupply, maxSupply, 1e8);
        amount = bound(amount, 1, 1000 * (10 ** uint256(shareDecimals)));
        vm.warp(ctx.start + 1);

        uint256 expected = _expectedCost(amount, 1e8, shareDecimals, 1e8);
        ctx.stable.mint(buyer, expected);
        uint256 buyerSharesBefore = ctx.token.balanceOf(buyer);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), expected);
        p.salesManager.buy(ctx.saleId, amount, buyer, address(ctx.stable), expected);
        vm.stopPrank();

        assertEq(ctx.token.balanceOf(buyer) - buyerSharesBefore, amount, "shares minted");
    }

    // buy: recipient and time gates

    function test_buy_rejects_zero_recipient() public {
        BasicSaleCtx memory ctx = _setupBasicSale("ZRC", "ZRC", 100, 1e8);
        vm.warp(ctx.start + 1);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Sale_InvalidRecipient"));
        p.salesManager.buy(ctx.saleId, 10, ZERO, address(ctx.stable), 10_000_000);
        vm.stopPrank();
    }

    function test_buy_reverts_before_sale_start() public {
        BasicSaleCtx memory ctx = _setupBasicSale("START", "STR", 100, 1e8);

        // Try to buy before start - should revert
        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Sale_NotStarted"));
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();

        // Warp to start time
        vm.warp(ctx.start + 1);

        // Now should succeed
        vm.prank(buyer);
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        assertEq(ctx.token.balanceOf(buyer), 10);
    }

    function test_buy_after_deadline_reverts() public {
        BasicSaleCtx memory ctx = _setupBasicSale("BADL", "BADL", 100, 1e8);
        vm.warp(ctx.deadline + 1);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Sale_Ended"));
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
    }

    function test_buy_at_exact_start_timestamp_succeeds() public {
        BasicSaleCtx memory ctx = _setupBasicSale("BST", "BST", 100, 1e8);
        vm.warp(ctx.start);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
        assertEq(ctx.token.balanceOf(buyer), 10);
    }

    function test_buy_at_exact_deadline_timestamp_succeeds() public {
        BasicSaleCtx memory ctx = _setupBasicSale("BDL", "BDL", 100, 1e8);
        vm.warp(ctx.deadline);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
        assertEq(ctx.token.balanceOf(buyer), 10);
    }

    // buy: oracle failures and bounds

    function test_setPaymentTokenOracle_to_zero_then_buy_reverts() public {
        BasicSaleCtx memory ctx = _setupBasicSale("OZ", "OZ", 100, 1e8);

        vm.prank(salesManagerSalesConfig);
        p.salesManager.setPaymentTokenOracle(address(ctx.stable), address(0), 0, 0);

        vm.warp(ctx.start + 1);
        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Sale_OracleNotConfigured"));
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
    }

    function test_buy_with_oracle_zero_price_reverts_invalid_price() public {
        BasicSaleCtx memory ctx = _setupBasicSale("OZP", "OZP", 100, 1e8);
        ctx.oracle.updatePrice(0);
        vm.warp(ctx.start + 1);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Sale_InvalidPrice"));
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
    }

    function test_buy_with_oracle_negative_price_reverts_invalid_price() public {
        BasicSaleCtx memory ctx = _setupBasicSale("ONP", "ONP", 100, 1e8);
        ctx.oracle.updatePrice(-1);
        vm.warp(ctx.start + 1);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Sale_InvalidPrice"));
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
    }

    function test_buy_with_oracle_price_normalizing_to_zero_reverts_invalid_price() public {
        BasicSaleCtx memory ctx = _setupBasicSale("ONZ", "ONZ", 100, 1e8);
        MockAggregatorV3 tinyOracle = new MockAggregatorV3(19, 1);
        vm.prank(salesManagerSalesConfig);
        p.salesManager.setPaymentTokenOracle(address(ctx.stable), address(tinyOracle), 24 hours, type(uint256).max);
        vm.warp(ctx.start + 1);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Sale_InvalidPrice"));
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
    }

    function test_buy_with_oracle_updatedAt_zero_reverts_price_not_updated() public {
        BasicSaleCtx memory ctx = _setupBasicSale("OUT", "OUT", 100, 1e8);
        ctx.oracle.updateTimestamp(0);
        vm.warp(ctx.start + 1);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Sale_PriceNotUpdated"));
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
    }

    function test_buy_with_oracle_stale_timestamp_reverts_stale_price() public {
        BasicSaleCtx memory ctx = _setupBasicSale("OST", "OST", 100, 1e8);
        vm.prank(salesManagerSalesConfig);
        p.salesManager.setPaymentTokenOracle(address(ctx.stable), address(ctx.oracle), 5 minutes, type(uint256).max);
        vm.warp(ctx.deadline - 1);
        ctx.oracle.updateTimestamp(1);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Sale_StalePrice"));
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
    }

    function test_buy_at_oracle_staleness_boundary_succeeds() public {
        BasicSaleCtx memory ctx = _setupBasicSale("OBD", "OBD", 100, 1e8);
        vm.prank(salesManagerSalesConfig);
        p.salesManager.setPaymentTokenOracle(address(ctx.stable), address(ctx.oracle), 5 minutes, type(uint256).max);
        vm.warp(ctx.deadline - 1);
        uint256 maxDelay = 5 minutes;
        ctx.oracle.updateTimestamp(block.timestamp - maxDelay);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
        assertEq(ctx.token.balanceOf(buyer), 10);
    }

    function test_buy_reverts_when_price_above_ceiling() public {
        BasicSaleCtx memory ctx = _setupBasicSale("CEIL", "CEIL", 100, 1e8);
        // Stable oracle reports $1 (1e8). Set ceiling to $0.50 (5e7) so the price exceeds it.
        vm.prank(salesManagerSalesConfig);
        p.salesManager.setPaymentTokenOracle(address(ctx.stable), address(ctx.oracle), 1 hours, 5e7);
        vm.warp(ctx.start + 1);
        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Sale_PriceAboveCeiling"));
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
    }

    function testFuzz_buy_reverts_above_ceiling(uint256 oracleAns, uint256 ceiling) public {
        BasicSaleCtx memory ctx = _setupBasicSale("FZC", "FZC", 1000, 1e8);
        oracleAns = bound(oracleAns, 2, 1e12);
        ceiling = bound(ceiling, 1, oracleAns - 1);

        vm.prank(salesManagerSalesConfig);
        p.salesManager.setPaymentTokenOracle(address(ctx.stable), address(ctx.oracle), 1 hours, ceiling);
        ctx.oracle.updatePrice(int256(oracleAns));
        vm.warp(ctx.start + 1);

        ctx.stable.mint(buyer, type(uint128).max);
        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), type(uint128).max);
        vm.expectRevert(bytes("Sale_PriceAboveCeiling"));
        p.salesManager.buy(ctx.saleId, 1, buyer, address(ctx.stable), type(uint128).max);
        vm.stopPrank();
    }

    // buy: payment token, rounding, reentrancy, KYC

    function test_buy_reverts_for_fee_on_transfer_payment_token() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "FOT", "FOT", DEFAULT_MAX_SUPPLY);
        // prepare controller: set caps, unpause
        p.tokenController.setTokenCapsInitial(address(token), p.tokenController.PAUSABLE_BIT());
        vm.stopPrank();

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        // register buyer identity (required even if no claim topics)
        p.registerIdentity(vm, identityRegistryAgent, buyer);

        // fee-on-transfer payment token + oracle
        address feeCollector = vm.addr(4242);
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken("FOTUSD", "FOTUSD", 6, 100, feeCollector); // 1% fee
        fot.mint(buyer, 1_000_000_000); // 1000 tokens
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000); // 1 token = 1 USD

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(fot), true);
        p.salesManager.setPaymentTokenOracle(address(fot), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        // create sale
        uint256 priceUsdPerShare = 1e8; // $1
        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);

        vm.prank(salesManagerSalesOperator);
        p.salesManager
            .createSale(address(token), _single(address(fot)), multisig, 100, priceUsdPerShare, start, deadline);

        uint256 saleId = p.salesManager.saleCount() - 1;

        // Warp to start time
        vm.warp(start + 1);

        uint256 buyerBefore = fot.balanceOf(buyer);
        uint256 feeCollectorBefore = fot.balanceOf(feeCollector);
        uint256 treasuryBefore = fot.balanceOf(multisig);

        vm.startPrank(buyer);
        fot.approve(address(p.salesManager), 10_000_000); // 10 tokens max
        vm.expectRevert(bytes("Sale_TransferAmountMismatch"));
        p.salesManager.buy(saleId, 10, buyer, address(fot), 10_000_000);
        vm.stopPrank();

        // Whole tx reverted: balances unchanged, no fee collected
        assertEq(fot.balanceOf(buyer), buyerBefore);
        assertEq(fot.balanceOf(feeCollector), feeCollectorBefore);
        assertEq(fot.balanceOf(multisig), treasuryBefore);
        assertEq(token.balanceOf(buyer), 0);
    }

    function test_buy_reverts_when_global_payment_token_disabled_after_sale_creation() public {
        BasicSaleCtx memory ctx = _setupBasicSale("GPD", "GPD", 100, 1e8);
        vm.warp(ctx.start + 1);

        vm.prank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(ctx.stable), false);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Sale_PaymentTokenNotAllowed"));
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
    }

    function test_buy_succeeds_again_after_global_payment_token_reenabled() public {
        BasicSaleCtx memory ctx = _setupBasicSale("GPE", "GPE", 100, 1e8);
        vm.warp(ctx.start + 1);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(ctx.stable), false);
        p.salesManager.setAllowedPaymentToken(address(ctx.stable), true);
        vm.stopPrank();

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
        assertEq(ctx.token.balanceOf(buyer), 10);
    }

    function test_fractionalShare_buy_cannot_be_free() public {
        uint256 maxSupply = 1000 * 1e18;
        BasicSaleCtx memory ctx = _setupBasicSaleWithDecimals("FRF", "FRF", 18, maxSupply, 100 * 1e18, 1e8);
        vm.warp(ctx.start + 1);

        uint256 treasuryBefore = ctx.stable.balanceOf(multisig);
        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 1);
        p.salesManager.buy(ctx.saleId, 1, buyer, address(ctx.stable), 1);
        vm.stopPrank();

        assertGt(ctx.stable.balanceOf(multisig) - treasuryBefore, 0, "treasury must receive payment");
        assertEq(ctx.token.balanceOf(buyer), 1);
    }

    function test_fractionalShare_buy_charges_rounded_up_or_reverts() public {
        uint256 maxSupply = 1000 * 1e18;
        BasicSaleCtx memory ctx = _setupBasicSaleWithDecimals("FRU", "FRU", 18, maxSupply, 100 * 1e18, 1e8);
        vm.warp(ctx.start + 1);

        uint256 treasuryBefore = ctx.stable.balanceOf(multisig);
        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 1);
        p.salesManager.buy(ctx.saleId, 1, buyer, address(ctx.stable), 1);
        vm.stopPrank();
        assertEq(ctx.stable.balanceOf(multisig) - treasuryBefore, 1);
    }

    function test_buy_rounds_payment_up_for_odd_usd_price() public {
        uint256 price333 = 33_300_000;
        BasicSaleCtx memory ctx = _setupBasicSale("R33", "R33", 100, price333);
        vm.warp(ctx.start + 1);

        uint256 usdCost = (10 * price333) / 1; // 0-decimal shares
        uint256 expectedPayment = _ceilPayment(usdCost, 6, 1e8);

        uint256 treasuryBefore = ctx.stable.balanceOf(multisig);
        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), expectedPayment);
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), expectedPayment);
        vm.stopPrank();
        assertEq(ctx.stable.balanceOf(multisig) - treasuryBefore, expectedPayment);

        BasicSaleCtx memory ctx2 = _setupBasicSale("R67", "R67", 100, 167_000_000, false);
        vm.warp(ctx2.start + 1);
        uint256 usdCost2 = 10 * 167_000_000;
        uint256 expectedPayment2 = _ceilPayment(usdCost2, 6, 1e8);
        treasuryBefore = ctx2.stable.balanceOf(multisig);
        vm.startPrank(buyer);
        ctx2.stable.approve(address(p.salesManager), expectedPayment2);
        p.salesManager.buy(ctx2.saleId, 10, buyer, address(ctx2.stable), expectedPayment2);
        vm.stopPrank();
        assertEq(ctx2.stable.balanceOf(multisig) - treasuryBefore, expectedPayment2);
    }

    function test_buy_reverts_when_maxPayment_matches_floor_but_not_ceil() public {
        uint256 price333 = 33_300_000;
        BasicSaleCtx memory ctx = _setupBasicSale("RSL", "RSL", 100, price333);
        vm.warp(ctx.start + 1);

        uint256 usdCost = 10 * price333;
        uint256 ceilPayment = _ceilPayment(usdCost, 6, 1e8);
        uint256 maxPayment = ceilPayment - 1;

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), ceilPayment);
        vm.expectRevert(bytes("Sale_MaxPaymentExceeded"));
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), maxPayment);
        vm.stopPrank();
    }

    function testFuzz_buy_respects_maxPayment(uint256 amount, uint256 maxPay) public {
        BasicSaleCtx memory ctx = _setupBasicSale("FZM", "FZM", 1000, 1e8);
        amount = bound(amount, 1, 1000);
        vm.warp(ctx.start + 1);

        uint256 expected = _expectedCost(amount, 1e8, 0, 1e8);
        maxPay = bound(maxPay, 0, expected - 1);
        ctx.stable.mint(buyer, expected);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), expected);
        vm.expectRevert(bytes("Sale_MaxPaymentExceeded"));
        p.salesManager.buy(ctx.saleId, amount, buyer, address(ctx.stable), maxPay);
        vm.stopPrank();
    }

    function test_buy_reentrancy_blocked() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "REN", "REN", DEFAULT_MAX_SUPPLY);
        p.tokenController.setTokenCapsInitial(address(token), p.tokenController.PAUSABLE_BIT());
        vm.stopPrank();
        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));
        p.registerIdentity(vm, identityRegistryAgent, buyer);

        MaliciousToken malToken = new MaliciousToken();
        malToken.setSalesManager(address(p.salesManager));
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);
        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(malToken), true);
        p.salesManager.setPaymentTokenOracle(address(malToken), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);
        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(malToken)), multisig, 100, 1e8, start, deadline);
        uint256 saleId = p.salesManager.saleCount() - 1;
        vm.warp(start + 1);

        malToken.configureAttack(saleId, buyer);
        malToken.mint(buyer, 1_000_000);
        vm.prank(buyer);
        malToken.approve(address(p.salesManager), 1_000_000);

        vm.prank(buyer);
        p.salesManager.buy(saleId, 1, buyer, address(malToken), 1_000_000);

        assertTrue(malToken.reentrancyBlocked());
        assertFalse(malToken.unexpectedRevert());
        assertEq(malToken.revertReason(), "ReentrancyGuard: reentrant call");
        assertEq(token.balanceOf(buyer), 1);
    }

    function test_permissioned_buy_requires_KYC_claim() public {
        uint256 KYC_TOPIC = 7;
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "KYC", "KYC", 1000);

        // add claim topic + trusted issuer on token-specific registries (owned by multisig after token creation)
        IdentityRegistry ir = IdentityRegistry(address(token.identityRegistry()));
        ClaimTopicsRegistry ctr = ClaimTopicsRegistry(address(ir.topicsRegistry()));
        TrustedIssuersRegistry tir = TrustedIssuersRegistry(address(ir.issuersRegistry()));

        vm.startPrank(multisig);
        ctr.addClaimTopic(KYC_TOPIC);
        tir.addTrustedIssuer(IClaimIssuer(address(p.claimIssuer)), _singleUint(KYC_TOPIC));
        vm.stopPrank();

        vm.startPrank(factoryShareDeployer);
        p.tokenController.setTokenCapsInitial(address(token), p.tokenController.PAUSABLE_BIT());
        vm.stopPrank();

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        // register buyer identity but no claim yet
        p.registerIdentity(vm, identityRegistryAgent, buyer);

        MockToken stable = new MockToken("USD", "USD", 6);
        stable.mint(buyer, 1_000_000_000);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);

        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 50, 1e8, start, deadline);
        uint256 saleId = p.salesManager.saleCount() - 1;

        // Warp to start time
        vm.warp(start + 1);

        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Identity is not verified."));
        p.salesManager.buy(saleId, 5, buyer, address(stable), 10_000_000);
        vm.stopPrank();

        // minimal unblock: remove topic (ClaimIssuer signature flow omitted in this Foundry port)
        vm.prank(multisig);
        ctr.removeClaimTopic(KYC_TOPIC);

        vm.prank(buyer);
        p.salesManager.buy(saleId, 5, buyer, address(stable), 10_000_000);
        assertEq(token.balanceOf(buyer), 5);
    }

    function test_permissioned_buy_succeeds_with_valid_claim_issuer_signature() public {
        uint256 kycTopic = 7;
        (Token token, uint256 saleId, MockToken stable) = _setupPermissionedSale(kycTopic);
        _addValidKycClaim(token, buyer, kycTopic);

        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 10_000_000);
        p.salesManager.buy(saleId, 5, buyer, address(stable), 10_000_000);
        vm.stopPrank();
        assertEq(token.balanceOf(buyer), 5);
    }

    function test_permissioned_buy_reverts_without_required_claim() public {
        uint256 kycTopic = 7;
        (Token token, uint256 saleId, MockToken stable) = _setupPermissionedSale(kycTopic);
        p.registerIdentity(vm, identityRegistryAgent, buyer);

        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Identity is not verified."));
        p.salesManager.buy(saleId, 5, buyer, address(stable), 10_000_000);
        vm.stopPrank();
        assertEq(token.balanceOf(buyer), 0);
    }

    function test_permissioned_buy_reverts_with_wrong_claim_topic() public {
        uint256 kycTopic = 7;
        (Token token, uint256 saleId, MockToken stable) = _setupPermissionedSale(kycTopic);
        _addValidKycClaim(token, buyer, 99);

        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Identity is not verified."));
        p.salesManager.buy(saleId, 5, buyer, address(stable), 10_000_000);
        vm.stopPrank();
        assertEq(token.balanceOf(buyer), 0);
    }

    function test_permissioned_buy_reverts_with_bad_signature() public {
        uint256 kycTopic = 7;
        (Token token, uint256 saleId, MockToken stable) = _setupPermissionedSale(kycTopic);
        p.registerIdentity(vm, identityRegistryAgent, buyer);
        IdentityRegistry ir = IdentityRegistry(address(token.identityRegistry()));
        IIdentity userIdentity = ir.identity(buyer);
        vm.prank(buyer);
        userIdentity.addKey(keccak256(abi.encode(buyer)), 3, 1);

        // Add signer99 as a CLAIM-purpose key in the issuer so addClaim accepts the sig
        address signer99 = vm.addr(99);
        bytes32 signer99Key = keccak256(abi.encode(signer99));
        vm.prank(claimIssuer);
        IClaimIssuer(address(p.claimIssuer)).addKey(signer99Key, 3, 1);

        // Sign with key 99 — valid at add time because signer99 is in the issuer
        bytes memory claimData = hex"0042";
        bytes32 dataHash = keccak256(abi.encode(address(userIdentity), kycTopic, claimData));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(99, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(buyer);
        userIdentity.addClaim(kycTopic, 1, address(p.claimIssuer), sig, claimData, "");

        // Revoke signer99 from the issuer — claim signature is now invalid
        vm.prank(claimIssuer);
        IClaimIssuer(address(p.claimIssuer)).removeKey(signer99Key, 3);

        // buy() reverts: isClaimValid fails because the signing key has been revoked
        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Identity is not verified."));
        p.salesManager.buy(saleId, 5, buyer, address(stable), 10_000_000);
        vm.stopPrank();
        assertEq(token.balanceOf(buyer), 0);
    }

    // Sale lifecycle

    function test_cancelSale_blocks_subsequent_buy() public {
        BasicSaleCtx memory ctx = _setupBasicSale("CAN", "CAN", 100, 1e8);
        vm.warp(ctx.start + 1);

        vm.prank(salesManagerSalesOperator);
        p.salesManager.cancelSale(ctx.saleId);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("Sale_NotActive"));
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
    }

    function test_cancelSale_blocks_subsequent_fiat_fulfillment() public {
        BasicSaleCtx memory ctx = _setupBasicSale("CFI", "CFI", 100, 1e8);
        address recipient = vm.addr(4567);
        p.registerIdentity(vm, identityRegistryAgent, recipient);
        vm.warp(ctx.start + 1);

        vm.prank(salesManagerSalesOperator);
        p.salesManager.cancelSale(ctx.saleId);

        vm.prank(fiatOrderSigner);
        vm.expectRevert(bytes("Sale_NotActive"));
        p.salesManager.fulfillFiatOrder(ctx.saleId, 10, recipient, keccak256("ref-cancel"));
    }

    function test_cancelSale_reverts_if_already_cancelled() public {
        BasicSaleCtx memory ctx = _setupBasicSale("C2X", "C2X", 100, 1e8);
        vm.prank(salesManagerSalesOperator);
        p.salesManager.cancelSale(ctx.saleId);

        vm.prank(salesManagerSalesOperator);
        vm.expectRevert(bytes("Sale_DoesNotExist"));
        p.salesManager.cancelSale(ctx.saleId);
    }

    function test_pause_unpause_sale() public {
        BasicSaleCtx memory ctx = _setupBasicSale("P", "P", 50, 1e8);

        // Warp to start time
        vm.warp(ctx.start + 1);

        vm.prank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);

        vm.prank(salesManagerSalesOperator);
        p.salesManager.pauseSale(ctx.saleId);

        vm.startPrank(buyer);
        vm.expectRevert(bytes("Sale_Paused"));
        p.salesManager.buy(ctx.saleId, 5, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();

        vm.prank(salesManagerSalesOperator);
        p.salesManager.unpauseSale(ctx.saleId);

        vm.prank(buyer);
        p.salesManager.buy(ctx.saleId, 5, buyer, address(ctx.stable), 10_000_000);
        assertEq(ctx.token.balanceOf(buyer), 5);
    }

    // updateSale*

    function test_updateSaleFundsRecipient_routes_funds() public {
        BasicSaleCtx memory ctx = _setupBasicSale("F", "F", 50, 1e8);

        address newRecipient = vm.addr(1234);

        vm.prank(salesManagerFundsAdmin);
        p.salesManager.updateSaleFundsRecipient(ctx.saleId, newRecipient);

        // Warp to start time
        vm.warp(ctx.start + 1);

        uint256 before = ctx.stable.balanceOf(newRecipient);

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        p.salesManager.buy(ctx.saleId, 5, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();
        uint256 afterBal = ctx.stable.balanceOf(newRecipient);
        assertEq(afterBal - before, 5_000_000);
    }

    function test_updateSalePaymentTokensAllowed_requires_allowlist_and_oracle() public {
        BasicSaleCtx memory ctx = _setupBasicSale("U", "U", 50, 1e8);

        // new token not allowlisted
        MockToken unallowed = new MockToken("UNL", "UNL", 6);

        vm.startPrank(salesManagerSalesOperator);
        vm.expectRevert(bytes("Sale_PaymentTokenNotAllowed"));
        p.salesManager.updateSalePaymentTokensAllowed(ctx.saleId, _single(address(unallowed)));
        vm.stopPrank();

        // allowlist but no oracle

        vm.prank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(unallowed), true);

        vm.startPrank(salesManagerSalesOperator);
        vm.expectRevert(bytes("Sale_OracleNotConfigured"));
        p.salesManager.updateSalePaymentTokensAllowed(ctx.saleId, _single(address(unallowed)));
        vm.stopPrank();

        // set oracle then succeed
        MockAggregatorV3 oracle2 = new MockAggregatorV3(8, 100_000_000);

        vm.prank(salesManagerSalesConfig);
        p.salesManager.setPaymentTokenOracle(address(unallowed), address(oracle2), 24 hours, type(uint256).max);

        vm.prank(salesManagerSalesOperator);
        p.salesManager.updateSalePaymentTokensAllowed(ctx.saleId, _single(address(unallowed)));
        (, address[] memory allowed,,,,,,,,) = p.salesManager.getSale(ctx.saleId);
        assertEq(allowed.length, 1);
        assertEq(allowed[0], address(unallowed));
    }

    function test_updateSalePriceUsdPerShare_affects_next_buy() public {
        BasicSaleCtx memory ctx = _setupBasicSale("PRU", "PRU", 100, 1e8);
        vm.warp(ctx.start + 1);

        vm.prank(salesManagerSalesOperator);
        p.salesManager.updateSalePriceUsdPerShare(ctx.saleId, 2e8);

        uint256 treasuryBefore = ctx.stable.balanceOf(multisig);
        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 20_000_000);
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 20_000_000);
        vm.stopPrank();
        assertEq(ctx.stable.balanceOf(multisig) - treasuryBefore, 20_000_000);
    }

    function test_updateSalePriceUsdPerShare_rejects_zero_price() public {
        BasicSaleCtx memory ctx = _setupBasicSale("PRZ", "PRZ", 100, 1e8);
        vm.prank(salesManagerSalesOperator);
        vm.expectRevert(bytes("Sale_ZeroPrice"));
        p.salesManager.updateSalePriceUsdPerShare(ctx.saleId, 0);
    }

    function test_updateSalePriceUsdPerShare_reverts_for_nonexistent_sale() public {
        vm.prank(salesManagerSalesOperator);
        vm.expectRevert(bytes("Sale_DoesNotExist"));
        p.salesManager.updateSalePriceUsdPerShare(type(uint256).max, 1e8);
    }

    function test_updateSaleDeadline_rejects_above_uint64_max() public {
        BasicSaleCtx memory ctx = _setupBasicSale("UDL", "UDL", 50, 1e8);

        vm.prank(salesManagerSalesOperator);
        vm.expectRevert(bytes("Sale_InvalidDeadline"));
        p.salesManager.updateSaleDeadline(ctx.saleId, uint256(type(uint64).max) + 1);
    }

    // fulfillFiatOrder

    function test_fulfillFiatOrder_respects_pause_and_deadline() public {
        BasicSaleCtx memory ctx = _setupBasicSale("FFO", "FFO", 50, 1e8);
        address recipient = vm.addr(4567);
        p.registerIdentity(vm, identityRegistryAgent, recipient);

        // Warp to start time
        vm.warp(ctx.start + 1);

        // pause sale

        vm.prank(salesManagerSalesOperator);
        p.salesManager.pauseSale(ctx.saleId);

        vm.startPrank(fiatOrderSigner);
        vm.expectRevert(bytes("Sale_Paused"));
        p.salesManager.fulfillFiatOrder(ctx.saleId, 10, recipient, keccak256(bytes("ref")));
        vm.stopPrank();

        vm.prank(salesManagerSalesOperator);
        p.salesManager.unpauseSale(ctx.saleId);

        vm.prank(fiatOrderSigner);
        p.salesManager.fulfillFiatOrder(ctx.saleId, 10, recipient, keccak256(bytes("ref")));
        assertEq(ctx.token.balanceOf(recipient), 10);
        (,,, uint256 remaining,,,,,,) = p.salesManager.getSale(ctx.saleId);
        assertEq(remaining, 40);
    }

    function test_fulfillFiatOrder_zero_amount_reverts() public {
        BasicSaleCtx memory ctx = _setupBasicSale("F0", "F0", 50, 1e8);
        address recipient = vm.addr(4567);
        p.registerIdentity(vm, identityRegistryAgent, recipient);
        vm.warp(ctx.start + 1);

        vm.prank(fiatOrderSigner);
        vm.expectRevert(bytes("Sale_AmountInvalid"));
        p.salesManager.fulfillFiatOrder(ctx.saleId, 0, recipient, keccak256(bytes("ref1")));
    }

    function test_fulfillFiatOrder_zero_recipient_reverts() public {
        BasicSaleCtx memory ctx = _setupBasicSale("FR0", "FR0", 50, 1e8);
        vm.warp(ctx.start + 1);

        vm.prank(fiatOrderSigner);
        vm.expectRevert(bytes("Sale_InvalidRecipient"));
        p.salesManager.fulfillFiatOrder(ctx.saleId, 10, ZERO, keccak256(bytes("ref2")));
    }

    function test_fulfillFiatOrder_amount_exceeds_remaining_reverts() public {
        BasicSaleCtx memory ctx = _setupBasicSale("FEX", "FEX", 10, 1e8);
        address recipient = vm.addr(4568);
        p.registerIdentity(vm, identityRegistryAgent, recipient);
        vm.warp(ctx.start + 1);

        vm.prank(fiatOrderSigner);
        vm.expectRevert(bytes("Sale_AmountInvalid"));
        p.salesManager.fulfillFiatOrder(ctx.saleId, 11, recipient, keccak256(bytes("ref3")));
    }

    function test_fulfillFiatOrder_rejects_duplicate_reference() public {
        BasicSaleCtx memory ctx = _setupBasicSale("FDR", "FDR", 100, 1e8);
        address recipient = vm.addr(4567);
        p.registerIdentity(vm, identityRegistryAgent, recipient);
        vm.warp(ctx.start + 1);
        bytes32 ref = keccak256("dup-ref");

        vm.startPrank(fiatOrderSigner);
        p.salesManager.fulfillFiatOrder(ctx.saleId, 10, recipient, ref);
        vm.expectRevert(bytes("Sale_FiatOrderReferenceAlreadyFulfilled"));
        p.salesManager.fulfillFiatOrder(ctx.saleId, 5, recipient, ref);
        vm.stopPrank();
    }

    function test_fulfillFiatOrder_same_reference_different_sales_policy() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "FSR", "FSR", 200);
        p.tokenController.setTokenCapsInitial(address(token), p.tokenController.PAUSABLE_BIT());
        vm.stopPrank();
        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));
        address recipient = vm.addr(4567);
        p.registerIdentity(vm, identityRegistryAgent, recipient);

        MockToken stable = new MockToken("USD", "USD", 6);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);
        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);
        vm.startPrank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 50, 1e8, start, deadline);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 50, 1e8, start, deadline);
        vm.stopPrank();
        uint256 saleId0 = p.salesManager.saleCount() - 2;
        uint256 saleId1 = p.salesManager.saleCount() - 1;
        vm.warp(start + 1);

        bytes32 ref = keccak256("global-ref");
        vm.prank(fiatOrderSigner);
        p.salesManager.fulfillFiatOrder(saleId0, 10, recipient, ref);

        vm.prank(fiatOrderSigner);
        vm.expectRevert(bytes("Sale_FiatOrderReferenceAlreadyFulfilled"));
        p.salesManager.fulfillFiatOrder(saleId1, 10, recipient, ref);
    }

    function test_fulfillFiatOrder_zero_reference_policy() public {
        BasicSaleCtx memory ctx = _setupBasicSale("FZR", "FZR", 100, 1e8);
        address recipient = vm.addr(4567);
        p.registerIdentity(vm, identityRegistryAgent, recipient);
        vm.warp(ctx.start + 1);

        vm.prank(fiatOrderSigner);
        vm.expectRevert(bytes("Sale_InvalidFiatOrderReference"));
        p.salesManager.fulfillFiatOrder(ctx.saleId, 10, recipient, bytes32(0));
    }

    function test_fulfillFiatOrder_failed_mint_does_not_mark_reference() public {
        BasicSaleCtx memory ctx = _setupBasicSale("FFM", "FFM", 100, 1e8);
        address unregistered = vm.addr(9999);
        vm.warp(ctx.start + 1);
        bytes32 ref = keccak256("fail-mint-ref");

        vm.prank(fiatOrderSigner);
        vm.expectRevert(bytes("Identity is not verified."));
        p.salesManager.fulfillFiatOrder(ctx.saleId, 10, unregistered, ref);

        assertFalse(p.salesManager.fiatOrderReferenceFulfilled(ref));
        assertEq(p.salesManager.getSaleRemainingSupply(ctx.saleId), 100);
        assertEq(p.salesManager.saleIdToSold(ctx.saleId), 0);
    }

    function test_fulfillFiatOrder_after_cancel_reverts_not_active() public {
        BasicSaleCtx memory ctx = _setupBasicSale("FCA", "FCA", 100, 1e8);
        address recipient = vm.addr(4567);
        p.registerIdentity(vm, identityRegistryAgent, recipient);
        vm.warp(ctx.start + 1);

        vm.prank(salesManagerSalesOperator);
        p.salesManager.cancelSale(ctx.saleId);

        vm.prank(fiatOrderSigner);
        vm.expectRevert(bytes("Sale_NotActive"));
        p.salesManager.fulfillFiatOrder(ctx.saleId, 10, recipient, keccak256("ref-after-cancel"));
    }

    function test_fulfillFiatOrder_before_sale_start_reverts() public {
        BasicSaleCtx memory ctx = _setupBasicSale("FFBS", "FFBS", 100, 1e8);
        address recipient = vm.addr(4567);
        p.registerIdentity(vm, identityRegistryAgent, recipient);

        vm.prank(fiatOrderSigner);
        vm.expectRevert(bytes("Sale_NotStarted"));
        p.salesManager.fulfillFiatOrder(ctx.saleId, 5, recipient, keccak256("ref-before-start"));
    }

    function test_fulfillFiatOrder_after_deadline_reverts() public {
        BasicSaleCtx memory ctx = _setupBasicSale("FFAD", "FFAD", 100, 1e8);
        address recipient = vm.addr(4567);
        p.registerIdentity(vm, identityRegistryAgent, recipient);
        vm.warp(ctx.deadline + 1);

        vm.prank(fiatOrderSigner);
        vm.expectRevert(bytes("Sale_Ended"));
        p.salesManager.fulfillFiatOrder(ctx.saleId, 5, recipient, keccak256("ref-after-deadline"));
    }

    function test_fulfillFiatOrder_at_exact_start_and_deadline_succeeds() public {
        BasicSaleCtx memory ctx = _setupBasicSale("FFD", "FFD", 100, 1e8);
        address recipient = vm.addr(4567);
        p.registerIdentity(vm, identityRegistryAgent, recipient);

        vm.warp(ctx.start);
        vm.prank(fiatOrderSigner);
        p.salesManager.fulfillFiatOrder(ctx.saleId, 5, recipient, keccak256("ref-start"));

        vm.warp(ctx.deadline);
        vm.prank(fiatOrderSigner);
        p.salesManager.fulfillFiatOrder(ctx.saleId, 5, recipient, keccak256("ref-deadline"));
        assertEq(ctx.token.balanceOf(recipient), 10);
    }

    // Funds management

    function test_rescueTokens_rejects_allowed_payment_tokens() public {
        // Setup: Create an allowed payment token
        MockToken allowedToken = new MockToken("USDC", "USDC", 6);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(allowedToken), true);
        p.salesManager.setPaymentTokenOracle(address(allowedToken), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        // Send some tokens to SalesManager (simulating accidental transfer)
        allowedToken.mint(address(p.salesManager), 100_000_000); // 100 USDC
        address recipient = vm.addr(9999);

        // Attempt to rescue allowed payment token - should fail
        vm.startPrank(salesManagerFundsAdmin);
        vm.expectRevert(bytes("Rescue_UseWithdrawFundsForPaymentTokens"));
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
        MockToken randomToken = new MockToken("RANDOM", "RND", 18);
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
        MockToken randomToken = new MockToken("RANDOM", "RND", 18);
        randomToken.mint(address(p.salesManager), 1_000_000_000_000_000_000);

        vm.startPrank(salesManagerFundsAdmin);
        vm.expectRevert(bytes("Rescue_InvalidRecipient"));
        p.salesManager.rescueTokens(address(randomToken), ZERO, 100_000_000_000_000_000);
        vm.stopPrank();
    }

    function test_withdrawFunds_succeeds_for_allowed_payment_tokens() public {
        // Setup: Create and allowlist payment tokens
        MockToken usdc = new MockToken("USDC", "USDC", 6);
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        MockAggregatorV3 oracle1 = new MockAggregatorV3(8, 100_000_000);
        MockAggregatorV3 oracle2 = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(usdc), true);
        p.salesManager.setPaymentTokenOracle(address(usdc), address(oracle1), 24 hours, type(uint256).max);
        p.salesManager.setAllowedPaymentToken(address(usdt), true);
        p.salesManager.setPaymentTokenOracle(address(usdt), address(oracle2), 24 hours, type(uint256).max);
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
        MockToken unallowedToken = new MockToken("UNL", "UNL", 18);
        unallowedToken.mint(address(p.salesManager), 1_000_000_000_000_000_000);
        address recipient = vm.addr(6666);

        vm.startPrank(salesManagerFundsAdmin);
        vm.expectRevert(bytes("Sale_PaymentTokenNotAllowed"));
        p.salesManager.withdrawFunds(_single(address(unallowedToken)), recipient, _singleUint(500_000_000_000_000_000));
        vm.stopPrank();

        // Verify tokens are still in SalesManager
        assertEq(unallowedToken.balanceOf(address(p.salesManager)), 1_000_000_000_000_000_000);
        assertEq(unallowedToken.balanceOf(recipient), 0);
    }

    function test_withdrawFunds_rejects_zero_address() public {
        MockToken usdc = new MockToken("USDC", "USDC", 6);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(usdc), true);
        p.salesManager.setPaymentTokenOracle(address(usdc), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        usdc.mint(address(p.salesManager), 100_000_000);

        vm.startPrank(salesManagerFundsAdmin);
        vm.expectRevert(bytes("Rescue_InvalidRecipient"));
        p.salesManager.withdrawFunds(_single(address(usdc)), ZERO, _singleUint(50_000_000));
        vm.stopPrank();
    }

    function test_withdrawFunds_rejects_length_mismatch() public {
        MockToken usdc = new MockToken("USDC", "USDC", 6);
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        MockAggregatorV3 oracle1 = new MockAggregatorV3(8, 100_000_000);
        MockAggregatorV3 oracle2 = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(usdc), true);
        p.salesManager.setPaymentTokenOracle(address(usdc), address(oracle1), 24 hours, type(uint256).max);
        p.salesManager.setAllowedPaymentToken(address(usdt), true);
        p.salesManager.setPaymentTokenOracle(address(usdt), address(oracle2), 24 hours, type(uint256).max);
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
        vm.expectRevert(bytes("Sale_LengthMismatch"));
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
        MockToken allowedToken = new MockToken("USDC", "USDC", 6);
        MockToken unallowedToken = new MockToken("UNL", "UNL", 18);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(allowedToken), true);
        p.salesManager.setPaymentTokenOracle(address(allowedToken), address(oracle), 24 hours, type(uint256).max);
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
        vm.expectRevert(bytes("Sale_PaymentTokenNotAllowed"));
        p.salesManager.withdrawFunds(tokens, recipient, amounts);
        vm.stopPrank();

        // Verify no tokens were transferred
        assertEq(allowedToken.balanceOf(address(p.salesManager)), 100_000_000);
        assertEq(unallowedToken.balanceOf(address(p.salesManager)), 1_000_000_000_000_000_000);
        assertEq(allowedToken.balanceOf(recipient), 0);
        assertEq(unallowedToken.balanceOf(recipient), 0);
    }

    function test_withdrawFunds_empty_arrays_noop() public {
        MockToken stable = new MockToken("USD", "USD", 6);
        address recipient = vm.addr(3333);

        stable.mint(address(p.salesManager), 123_000_000);
        stable.mint(recipient, 7_000_000);

        uint256 managerBefore = stable.balanceOf(address(p.salesManager));
        uint256 recipientBefore = stable.balanceOf(recipient);

        vm.prank(salesManagerFundsAdmin);
        p.salesManager.withdrawFunds(new address[](0), recipient, new uint256[](0));

        assertEq(stable.balanceOf(address(p.salesManager)), managerBefore);
        assertEq(stable.balanceOf(recipient), recipientBefore);
    }

    // Config (payment token / oracle)

    function test_event_PaymentTokenOracleSet_emitted() public {
        MockToken stable = new MockToken("US2", "US2", 6);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);
        vm.expectEmit(true, false, false, true, address(p.salesManager));
        emit PaymentTokenOracleSet(address(stable), address(oracle), 1 hours, type(uint256).max);
        vm.prank(salesManagerSalesConfig);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle), 1 hours, type(uint256).max);
    }

    function test_setPaymentTokenOracle_rejects_delay_below_min() public {
        MockToken s = new MockToken("US3", "US3", 6);
        MockAggregatorV3 o = new MockAggregatorV3(8, 1e8);
        vm.prank(salesManagerSalesConfig);
        vm.expectRevert(bytes("Sale_InvalidOracleDelay"));
        p.salesManager.setPaymentTokenOracle(address(s), address(o), 59, type(uint256).max);
    }

    function test_setPaymentTokenOracle_rejects_delay_above_max() public {
        MockToken s = new MockToken("US4", "US4", 6);
        MockAggregatorV3 o = new MockAggregatorV3(8, 1e8);
        vm.prank(salesManagerSalesConfig);
        vm.expectRevert(bytes("Sale_InvalidOracleDelay"));
        p.salesManager.setPaymentTokenOracle(address(s), address(o), 24 hours + 1, type(uint256).max);
    }

    function test_setPaymentTokenOracle_rejects_zero_ceiling() public {
        MockToken s = new MockToken("US5", "US5", 6);
        MockAggregatorV3 o = new MockAggregatorV3(8, 1e8);
        vm.prank(salesManagerSalesConfig);
        vm.expectRevert(bytes("Sale_InvalidMaxPrice"));
        p.salesManager.setPaymentTokenOracle(address(s), address(o), 1 hours, 0);
    }

    // Emergency pause

    function test_emergencyPause_blocks_buy_and_fulfillFiatOrder() public {
        BasicSaleCtx memory ctx = _setupBasicSale("EP", "EP", 100, 1e8);
        address recipient = vm.addr(4567);
        p.registerIdentity(vm, identityRegistryAgent, recipient);
        vm.warp(ctx.start + 1);

        vm.prank(salesManagerSalesOperator);
        p.salesManager.setEmergencyPause();

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        vm.expectRevert(bytes("SalesManager_EmergencyPaused"));
        p.salesManager.buy(ctx.saleId, 10, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();

        vm.prank(fiatOrderSigner);
        vm.expectRevert(bytes("SalesManager_EmergencyPaused"));
        p.salesManager.fulfillFiatOrder(ctx.saleId, 10, recipient, keccak256("ref-ep"));
    }

    function test_emergencyPause_unset_restores_buy_and_fiat_fulfillment() public {
        BasicSaleCtx memory ctx = _setupBasicSale("EPU", "EPU", 100, 1e8);
        address recipient = vm.addr(4568);
        p.registerIdentity(vm, identityRegistryAgent, recipient);
        vm.warp(ctx.start + 1);

        vm.startPrank(salesManagerSalesOperator);
        p.salesManager.setEmergencyPause();
        p.salesManager.unsetEmergencyPause();
        vm.stopPrank();

        vm.startPrank(buyer);
        ctx.stable.approve(address(p.salesManager), 10_000_000);
        p.salesManager.buy(ctx.saleId, 5, buyer, address(ctx.stable), 10_000_000);
        vm.stopPrank();

        vm.prank(fiatOrderSigner);
        p.salesManager.fulfillFiatOrder(ctx.saleId, 5, recipient, keccak256("ref-epu"));
        assertEq(ctx.token.balanceOf(recipient), 5);
    }

    function test_emergencyPause_rejects_double_set_and_double_unset() public {
        vm.prank(salesManagerSalesOperator);
        p.salesManager.setEmergencyPause();

        vm.prank(salesManagerSalesOperator);
        vm.expectRevert(bytes("SalesManager_AlreadyPaused"));
        p.salesManager.setEmergencyPause();

        vm.prank(salesManagerSalesOperator);
        p.salesManager.unsetEmergencyPause();

        vm.prank(salesManagerSalesOperator);
        vm.expectRevert(bytes("SalesManager_NotPaused"));
        p.salesManager.unsetEmergencyPause();
    }

    // Cross-sale supply accounting

    function test_createSale_allows_oversubscription_but_second_sale_mint_can_revert_at_token_level() public {
        (Token token, MockToken stable,) = _setupCappedTokenAndPayment("OVR", "OVR", 100);

        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);
        vm.startPrank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 80, 1e8, start, deadline);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 80, 1e8, start, deadline);
        vm.stopPrank();

        uint256 saleId0 = p.salesManager.saleCount() - 2;
        uint256 saleId1 = p.salesManager.saleCount() - 1;
        vm.warp(start + 1);

        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 200_000_000);
        p.salesManager.buy(saleId0, 80, buyer, address(stable), 80_000_000);
        vm.expectRevert(bytes("Compliance not followed"));
        p.salesManager.buy(saleId1, 80, buyer, address(stable), 80_000_000);
        vm.stopPrank();

        assertEq(p.salesManager.getSaleRemainingSupply(saleId1), 80);
        assertEq(p.salesManager.saleIdToSold(saleId1), 0);
        assertEq(token.balanceOf(buyer), 80);
    }

    function test_buy_consumes_shared_maxSupply_across_sales() public {
        (Token token, MockToken stable,) = _setupCappedTokenAndPayment("CS2", "CS2", 100);

        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);
        vm.startPrank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 60, 1e8, start, deadline);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 60, 1e8, start, deadline);
        vm.stopPrank();
        uint256 saleId0 = p.salesManager.saleCount() - 2;
        uint256 saleId1 = p.salesManager.saleCount() - 1;
        vm.warp(start + 1);

        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 1_000_000_000);

        // Buying 60 from sale0 consumes 60 of the shared token maxSupply
        p.salesManager.buy(saleId0, 60, buyer, address(stable), 60_000_000);
        assertEq(token.balanceOf(buyer), 60);

        // 41 exceeds the 40 remaining in the token cap
        vm.expectRevert(bytes("Compliance not followed"));
        p.salesManager.buy(saleId1, 41, buyer, address(stable), 41_000_000);

        // 40 exactly fills the remaining cap
        p.salesManager.buy(saleId1, 40, buyer, address(stable), 40_000_000);
        assertEq(token.balanceOf(buyer), 100);
        vm.stopPrank();
    }

    function test_cancelSale_does_not_unmint_already_sold_supply() public {
        (Token token, MockToken stable,) = _setupCappedTokenAndPayment("CDS", "CDS", 100);

        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);
        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 50, 1e8, start, deadline);
        uint256 saleId0 = p.salesManager.saleCount() - 1;
        vm.warp(start + 1);

        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 1_000_000_000);
        p.salesManager.buy(saleId0, 20, buyer, address(stable), 20_000_000);
        vm.stopPrank();
        assertEq(token.balanceOf(buyer), 20);

        // Cancel — the 20 already minted are NOT returned to the token cap
        vm.prank(salesManagerSalesOperator);
        p.salesManager.cancelSale(saleId0);

        vm.warp(block.timestamp + 1);
        uint64 nowTs = uint64(block.timestamp);
        uint64 start2 = nowTs + 100;
        uint64 deadline2 = nowTs + 3600;

        // createSale rejects 81 because only 80 remain in the token cap (20 minted, not unminted on cancel)
        vm.prank(salesManagerSalesOperator);
        vm.expectRevert(bytes("Sale_SupplyExceedsCap"));
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 81, 1e8, start2, deadline2);

        // 80 is the exact remaining cap — createSale and the full buy both succeed
        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 80, 1e8, start2, deadline2);
        uint256 saleId1 = p.salesManager.saleCount() - 1;
        vm.warp(start2 + 1);

        vm.startPrank(buyer);
        p.salesManager.buy(saleId1, 80, buyer, address(stable), 80_000_000);
        assertEq(token.balanceOf(buyer), 100);
        vm.stopPrank();
    }

    function test_maxSupplyCap_reduced_mid_sale_mint_reverts_without_sale_accounting_change() public {
        (Token token, MockToken stable,) = _setupCappedTokenAndPayment("CAP", "CAP", 100);

        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);
        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 80, 1e8, start, deadline);
        uint256 saleId = p.salesManager.saleCount() - 1;

        IModularCompliance mc = IModularCompliance(address(token.compliance()));
        bytes memory setCap = abi.encodeWithSignature("setMaxSupply(uint256)", 50);
        vm.prank(multisig);
        mc.callModuleFunction(setCap, address(p.maxSupplyModule));

        vm.warp(start + 1);
        uint256 buyerBalBefore = token.balanceOf(buyer);
        uint256 treasuryBefore = stable.balanceOf(multisig);
        uint256 remainingBefore = p.salesManager.getSaleRemainingSupply(saleId);
        uint256 soldBefore = p.salesManager.saleIdToSold(saleId);

        vm.startPrank(buyer);
        stable.approve(address(p.salesManager), 80_000_000);
        vm.expectRevert(bytes("Compliance not followed"));
        p.salesManager.buy(saleId, 80, buyer, address(stable), 80_000_000);
        vm.stopPrank();

        assertEq(token.balanceOf(buyer), buyerBalBefore);
        assertEq(stable.balanceOf(multisig), treasuryBefore);
        assertEq(p.salesManager.getSaleRemainingSupply(saleId), remainingBefore);
        assertEq(p.salesManager.saleIdToSold(saleId), soldBefore);
    }

    // Views

    function test_getSaleTotalSupply_nonexistent_reverts() public {
        vm.expectRevert(bytes("Sale_DoesNotExist"));
        p.salesManager.getSaleTotalSupply(type(uint256).max);
    }

    function test_getSaleRemainingSupply_nonexistent_reverts() public {
        vm.expectRevert(bytes("Sale_DoesNotExist"));
        p.salesManager.getSaleRemainingSupply(type(uint256).max);
    }

    function test_getSale_nonexistent_returns_zero_share() public view {
        (address share,,,,,,,,,) = p.salesManager.getSale(type(uint256).max);
        assertEq(share, address(0));
    }

    // Helpers

    function _expectedCost(uint256 amount, uint256 priceUsdPerShare, uint8 shareDecimals, uint256 oraclePrice1e8)
        internal
        pure
        returns (uint256)
    {
        uint256 usdCost = Math.mulDiv(amount, priceUsdPerShare, 10 ** uint256(shareDecimals), Math.Rounding.Up);
        return Math.mulDiv(usdCost, 1e6, oraclePrice1e8, Math.Rounding.Up);
    }
}
