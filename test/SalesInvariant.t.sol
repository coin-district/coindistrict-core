// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {ProtocolFixture, Protocol, Accounts} from "./fixtures/ProtocolFixture.sol";
import {ShareTestUtils} from "./utils/ShareTestUtils.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {MockAggregatorV3} from "contracts/mocks/MockAggregatorV3.sol";
import {Token} from "@erc3643org/erc-3643/contracts/token/Token.sol";

contract SalesInvariantHandler is ProtocolFixture {
    using ShareTestUtils for Protocol;

    Protocol internal protocol;
    Accounts internal acc;
    address internal buyer;
    MockToken internal stable;
    Token internal token;
    uint256 public saleId;
    uint256 public originalSupply;
    uint256 public ghostSold;
    uint256 public ghostFiatSold;
    uint256 public ghostTreasuryReceived;
    uint256 public ghostBuyerBalance;
    bool public emergencyPaused;

    constructor() {
        acc = defaultAccounts();
        protocol = deployProtocol(acc);
        defaultRoleSetup(protocol, acc);
        addGlobalIrAgents(protocol, acc);

        buyer = acc.buyer;

        vm.startPrank(acc.factoryShareDeployer);
        token = protocol.createShare(acc.multisig, acc.identityRegistryAgent, "INV", "INV", 10_000);
        protocol.tokenController.setTokenCapsInitial(address(token), protocol.tokenController.PAUSABLE_BIT());
        vm.stopPrank();

        vm.prank(acc.tokenAgent);
        protocol.tokenController.unpause(address(token));

        protocol.registerIdentity(vm, acc.identityRegistryAgent, buyer);

        stable = new MockToken("USD", "USD", 6);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

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

    function buy(uint256 amount) external {
        if (emergencyPaused) return;
        uint256 remaining = protocol.salesManager.getSaleRemainingSupply(saleId);
        if (remaining == 0) return;

        amount = bound(amount, 1, remaining);
        uint256 cost = amount * 1_000_000;
        stable.mint(buyer, cost);

        vm.prank(buyer);
        stable.approve(address(protocol.salesManager), cost);
        uint256 treasuryBefore = stable.balanceOf(acc.multisig);
        uint256 buyerBefore = token.balanceOf(buyer);
        vm.prank(buyer);

        try protocol.salesManager.buy(saleId, amount, buyer, address(stable), cost) {
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

    function fulfillFiat(uint256 amount, uint256 refSeed) external {
        if (emergencyPaused) return;
        uint256 remaining = protocol.salesManager.getSaleRemainingSupply(saleId);
        if (remaining == 0) return;

        amount = bound(amount, 1, remaining);
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

    function getSaleTotalSupply() external view returns (uint256) {
        return protocol.salesManager.getSaleTotalSupply(saleId);
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

    function getMaxSupply() external view returns (uint256) {
        return 10_000;
    }

    function getTotalMinted() external view returns (uint256) {
        return token.totalSupply();
    }
}

contract SalesInvariantTest is Test {
    SalesInvariantHandler internal handler;

    function setUp() public {
        handler = new SalesInvariantHandler();
        targetContract(address(handler));
    }

    function invariant_sold_plus_remaining_constant() external view {
        assertEq(handler.getSaleTotalSupply(), handler.originalSupply());
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
}
