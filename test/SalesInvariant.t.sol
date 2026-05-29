// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {ProtocolFixture, Protocol, Accounts} from "./fixtures/ProtocolFixture.sol";
import {ShareTestUtils} from "./utils/ShareTestUtils.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {MockAggregatorV3} from "contracts/mocks/MockAggregatorV3.sol";
import {ISalesManager} from "contracts/ISalesManager.sol";
import {Token} from "@erc3643org/erc-3643/contracts/token/Token.sol";

contract SalesInvariantHandler is ProtocolFixture {
    using ShareTestUtils for Protocol;

    uint256 internal constant MAX_SUPPLY = 500;
    uint256 internal constant CHUNK = 64;

    Protocol internal protocol;
    Accounts internal acc;
    address internal buyer;
    MockToken internal stable;
    MockAggregatorV3 internal oracle;
    Token internal token;
    uint256 public saleId;
    uint256 public originalSupply;
    uint256 public ghostSold;
    uint256 public ghostFiatSold;
    uint256 public ghostTreasuryReceived;
    uint256 public ghostBuyerBalance;
    bool public emergencyPaused;
    bool public zeroAllowanceBuySucceeded;
    bool public unregisteredFiatFulfillmentSucceeded;
    bool public pausedBuyViolation;
    bool public pausedFiatViolation;

    constructor() {
        acc = defaultAccounts();
        protocol = deployProtocol(acc);
        defaultRoleSetup(protocol, acc);
        addGlobalIrAgents(protocol, acc);

        buyer = acc.buyer;

        vm.startPrank(acc.factoryShareDeployer);
        token = protocol.createShare(acc.multisig, acc.identityRegistryAgent, "INV", "INV", MAX_SUPPLY);
        protocol.tokenController.setTokenCapsInitial(address(token), protocol.tokenController.PAUSABLE_BIT());
        vm.stopPrank();

        vm.prank(acc.tokenAgent);
        protocol.tokenController.unpause(address(token));

        protocol.registerIdentity(vm, acc.identityRegistryAgent, buyer);

        stable = new MockToken("USD", "USD", 6);
        oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(acc.salesManagerSalesConfig);
        protocol.salesManager.setAllowedPaymentToken(address(stable), true);
        protocol.salesManager.setPaymentTokenOracle(address(stable), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        originalSupply = 500;
        uint64 saleStart = uint64(block.timestamp + 100);

        vm.prank(acc.salesManagerSalesOperator);
        protocol.salesManager
            .createSale(
                address(token), _single(address(stable)), acc.multisig, originalSupply, 1e8, saleStart, saleStart + 3600
            );
        saleId = protocol.salesManager.saleCount() - 1;
        vm.warp(saleStart + 1);
    }

    // Sales operations

    function buy(uint256 amount) external {
        if (emergencyPaused) return;
        uint256 remaining = protocol.salesManager.getSaleRemainingSupply(saleId);
        if (remaining == 0) return;
        amount = bound(amount, 1, remaining < CHUNK ? remaining : CHUNK);

        uint256 big = type(uint128).max;
        stable.mint(buyer, big);
        vm.prank(buyer);
        stable.approve(address(protocol.salesManager), big);

        uint256 treasuryBefore = stable.balanceOf(acc.multisig);
        uint256 buyerBefore = token.balanceOf(buyer);
        vm.prank(buyer);
        try protocol.salesManager.buy(saleId, amount, buyer, address(stable), big) {
            ghostSold += amount;
            ghostTreasuryReceived += stable.balanceOf(acc.multisig) - treasuryBefore;
            ghostBuyerBalance = token.balanceOf(buyer);
        } catch {
            assertEq(protocol.salesManager.getSaleRemainingSupply(saleId), remaining);
            assertEq(protocol.salesManager.saleIdToSold(saleId), ghostSold + ghostFiatSold);
            assertEq(token.balanceOf(buyer), buyerBefore);
            assertEq(stable.balanceOf(acc.multisig), treasuryBefore);
        }
    }

    function buyWithZeroAllowanceReverts(uint256 amount) external {
        if (emergencyPaused) return;
        uint256 remaining = protocol.salesManager.getSaleRemainingSupply(saleId);
        if (remaining == 0) return;
        amount = bound(amount, 1, remaining < CHUNK ? remaining : CHUNK);

        uint256 big = type(uint128).max;
        stable.mint(buyer, big);
        vm.prank(buyer);
        stable.approve(address(protocol.salesManager), 0);

        vm.prank(buyer);
        try protocol.salesManager.buy(saleId, amount, buyer, address(stable), big) {
            zeroAllowanceBuySucceeded = true;
        } catch {}
    }

    function fulfillFiat(uint256 amount, uint256 refSeed) external {
        if (emergencyPaused) return;
        uint256 remaining = protocol.salesManager.getSaleRemainingSupply(saleId);
        if (remaining == 0) return;

        amount = bound(amount, 1, remaining < CHUNK ? remaining : CHUNK);
        bytes32 ref = keccak256(abi.encode(refSeed, ghostFiatSold, ghostSold));
        if (protocol.salesManager.fiatOrderReferenceFulfilled(ref)) return;

        uint256 soldBefore = protocol.salesManager.saleIdToSold(saleId);
        uint256 remainingBefore = remaining;
        vm.prank(acc.fiatOrderSigner);
        try protocol.salesManager.fulfillFiatOrder(saleId, amount, buyer, ref) {
            ghostFiatSold += amount;
            ghostBuyerBalance = token.balanceOf(buyer);
        } catch {
            assertEq(protocol.salesManager.getSaleRemainingSupply(saleId), remainingBefore);
            assertEq(protocol.salesManager.saleIdToSold(saleId), soldBefore);
        }
    }

    function fulfillFiatToUnregisteredReverts(uint256 amount, uint256 refSeed) external {
        if (emergencyPaused) return;
        uint256 remaining = protocol.salesManager.getSaleRemainingSupply(saleId);
        if (remaining == 0) return;
        amount = bound(amount, 1, remaining < CHUNK ? remaining : CHUNK);

        bytes32 ref = keccak256(abi.encode("invalid-recipient", refSeed, amount));

        vm.prank(acc.fiatOrderSigner);
        try protocol.salesManager.fulfillFiatOrder(saleId, amount, acc.user1, ref) {
            unregisteredFiatFulfillmentSucceeded = true;
        } catch {}
    }

    // Oracle mutation support

    function updateOraclePrice(uint256 priceSeed) external {
        int256 newPrice = int256(bound(priceSeed, 1e6, 1e11));
        oracle.updatePrice(newPrice);
    }

    // Emergency pause operations and negative paths

    function pauseEmergency() external {
        if (emergencyPaused) return;
        vm.prank(acc.salesManagerSalesOperator);
        protocol.salesManager.setEmergencyPause();
        emergencyPaused = true;
    }

    function unpauseEmergency() external {
        if (!emergencyPaused) return;
        vm.prank(acc.salesManagerSalesOperator);
        protocol.salesManager.unsetEmergencyPause();
        emergencyPaused = false;
    }

    function buyWhileEmergencyPausedReverts(uint256 amount) external {
        if (!emergencyPaused) return;
        uint256 remaining = protocol.salesManager.getSaleRemainingSupply(saleId);
        amount = remaining == 0 ? 1 : bound(amount, 1, remaining);

        vm.prank(buyer);
        try protocol.salesManager.buy(saleId, amount, buyer, address(stable), type(uint128).max) {
            pausedBuyViolation = true;
        } catch Error(string memory) {
            pausedBuyViolation = true;
        } catch (bytes memory reason) {
            if (keccak256(reason) != keccak256(abi.encodeWithSelector(ISalesManager.EmergencyPausedErr.selector))) {
                pausedBuyViolation = true;
            }
        }
    }

    function fulfillFiatWhileEmergencyPausedReverts(uint256 amount, uint256 refSeed) external {
        if (!emergencyPaused) return;
        uint256 remaining = protocol.salesManager.getSaleRemainingSupply(saleId);
        amount = remaining == 0 ? 1 : bound(amount, 1, remaining);
        bytes32 ref = keccak256(abi.encode("paused-fiat", refSeed, amount));

        vm.prank(acc.fiatOrderSigner);
        try protocol.salesManager.fulfillFiatOrder(saleId, amount, buyer, ref) {
            pausedFiatViolation = true;
        } catch Error(string memory) {
            pausedFiatViolation = true;
        } catch (bytes memory reason) {
            if (keccak256(reason) != keccak256(abi.encodeWithSelector(ISalesManager.EmergencyPausedErr.selector))) {
                pausedFiatViolation = true;
            }
        }
    }

    // Observation getters

    function getSaleTotalSupply() external view returns (uint256) {
        return protocol.salesManager.getSaleTotalSupply(saleId);
    }

    function getSaleRemaining() external view returns (uint256) {
        return protocol.salesManager.getSaleRemainingSupply(saleId);
    }

    function getSaleSoldOnChain() external view returns (uint256) {
        return protocol.salesManager.saleIdToSold(saleId);
    }

    function getTreasuryBalance() external view returns (uint256) {
        return stable.balanceOf(acc.multisig);
    }

    function getBuyerBalance() external view returns (uint256) {
        return token.balanceOf(buyer);
    }

    function getMaxSupply() external pure returns (uint256) {
        return MAX_SUPPLY;
    }

    function getTotalMinted() external view returns (uint256) {
        return token.totalSupply();
    }
}

contract SalesInvariantTest is Test {
    SalesInvariantHandler internal handler;

    function setUp() public {
        handler = new SalesInvariantHandler();

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.fulfillFiat.selector;
        selectors[2] = handler.pauseEmergency.selector;
        selectors[3] = handler.unpauseEmergency.selector;
        selectors[4] = handler.updateOraclePrice.selector;
        selectors[5] = handler.buyWithZeroAllowanceReverts.selector;
        selectors[6] = handler.fulfillFiatToUnregisteredReverts.selector;
        selectors[7] = handler.buyWhileEmergencyPausedReverts.selector;
        selectors[8] = handler.fulfillFiatWhileEmergencyPausedReverts.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_sold_plus_remaining_constant() external view {
        assertEq(handler.getSaleTotalSupply(), handler.originalSupply());
    }

    function invariant_remaining_matches_ghost_sales() external view {
        assertEq(handler.getSaleRemaining() + handler.ghostSold() + handler.ghostFiatSold(), handler.originalSupply());
    }

    function invariant_sale_sold_matches_ghost() external view {
        assertEq(handler.getSaleSoldOnChain(), handler.ghostSold() + handler.ghostFiatSold());
    }

    function invariant_treasury_matches_ghost() external view {
        assertEq(handler.getTreasuryBalance(), handler.ghostTreasuryReceived());
    }

    function invariant_buyer_balance_matches_ghost() external view {
        assertEq(handler.getBuyerBalance(), handler.ghostBuyerBalance());
    }

    function invariant_total_minted_never_exceeds_max_supply() external view {
        assertLe(handler.getTotalMinted(), handler.getMaxSupply());
    }

    function invariant_zero_allowance_buy_never_succeeds() external view {
        assertFalse(handler.zeroAllowanceBuySucceeded());
    }

    function invariant_unregistered_fiat_fulfillment_never_succeeds() external view {
        assertFalse(handler.unregisteredFiatFulfillmentSucceeded());
    }

    function invariant_paused_buy_never_violates() external view {
        assertFalse(handler.pausedBuyViolation());
    }

    function invariant_paused_fiat_never_violates() external view {
        assertFalse(handler.pausedFiatViolation());
    }
}
