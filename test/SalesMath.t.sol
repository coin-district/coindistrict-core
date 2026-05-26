// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {SalesManager} from "contracts/SalesManager.sol";
import {MockAggregatorV3} from "contracts/mocks/MockAggregatorV3.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SalesManagerHarness is SalesManager {
    function exposedCalculateUsdCost(uint256 amount, uint256 priceUsdPerShare, uint8 shareDecimals)
        external
        pure
        returns (uint256)
    {
        return _calculateUsdCost(amount, priceUsdPerShare, shareDecimals);
    }

    function exposedGetTokenUsdPrice1e8(address aggregator) external view returns (uint256) {
        return _getTokenUsdPrice1e8(aggregator, 24 hours, type(uint256).max);
    }

    function exposedGetTokenUsdPrice1e8Params(address aggregator, uint256 maxDelay, uint256 maxPrice1e8)
        external
        view
        returns (uint256)
    {
        return _getTokenUsdPrice1e8(aggregator, maxDelay, maxPrice1e8);
    }
}

contract SalesMathTest is Test {
    SalesManagerHarness internal harness;

    function setUp() public {
        SalesManagerHarness impl = new SalesManagerHarness();
        harness = SalesManagerHarness(payable(address(new ERC1967Proxy(address(impl), ""))));
        harness.initialize(address(0xBEEF));
    }

    // _calculateUsdCost

    function testFuzz_calculateUsdCost_no_free_positive_amount(uint256 amount, uint256 price, uint8 decimals)
        public
        view
    {
        amount = bound(amount, 1, 1e30);
        price = bound(price, 1, 1e30);
        decimals = uint8(bound(decimals, 0, 18));

        uint256 usdCost = harness.exposedCalculateUsdCost(amount, price, decimals);
        assertGt(usdCost, 0);
    }

    function testFuzz_calculateUsdCost_monotonic_amount_and_price(uint256 amount, uint256 price, uint8 decimals)
        public
        view
    {
        amount = bound(amount, 1, 1e24);
        price = bound(price, 1, 1e24);
        decimals = uint8(bound(decimals, 0, 18));

        uint256 base = harness.exposedCalculateUsdCost(amount, price, decimals);
        uint256 moreAmount = harness.exposedCalculateUsdCost(amount + 1, price, decimals);
        uint256 higherPrice = harness.exposedCalculateUsdCost(amount, price + 1, decimals);
        assertGe(moreAmount, base);
        assertGe(higherPrice, base);
    }

    function test_calculateUsdCost_rounding_behavior_explicit() public view {
        uint256 cost = harness.exposedCalculateUsdCost(1, 1e8, 18);
        assertEq(cost, 1);
        cost = harness.exposedCalculateUsdCost(1e18, 1e8, 18);
        assertEq(cost, 1e8);
    }

    // _getTokenUsdPrice1e8

    function testFuzz_getTokenUsdPrice1e8_scaling_round_trip(uint8 decimals) public {
        decimals = uint8(bound(decimals, 6, 24));
        int256 rawPrice = int256(10 ** uint256(decimals));
        MockAggregatorV3 oracle = new MockAggregatorV3(decimals, rawPrice);

        uint256 normalized = harness.exposedGetTokenUsdPrice1e8(address(oracle));
        assertEq(normalized, 1e8);
    }

    function test_getTokenUsdPrice1e8_decimals_zero_scales_up() public {
        MockAggregatorV3 oracle = new MockAggregatorV3(0, 1);
        assertEq(harness.exposedGetTokenUsdPrice1e8(address(oracle)), 1e8);
    }

    function test_getTokenUsdPrice1e8_decimals_19_reverts_when_normalized_price_is_zero() public {
        // price=1 -> 1 * 1e8 / 1e19 truncates to zero and is unusable as a payment denominator.
        MockAggregatorV3 oracle = new MockAggregatorV3(19, 1);
        vm.expectRevert(bytes("Sale_InvalidPrice"));
        harness.exposedGetTokenUsdPrice1e8(address(oracle));

        // price=1e11 -> 1e11 * 1e8 / 1e19 = 1 (non-zero branch).
        MockAggregatorV3 oracle2 = new MockAggregatorV3(19, int256(1e11));
        uint256 normalized2 = harness.exposedGetTokenUsdPrice1e8(address(oracle2));
        assertGt(normalized2, 0);
    }

    function test_getTokenUsdPrice1e8_decimals_overflow_reverts() public {
        MockAggregatorV3 oracle = new MockAggregatorV3(0, type(int256).max);
        vm.expectRevert(stdError.arithmeticError);
        harness.exposedGetTokenUsdPrice1e8(address(oracle));
    }

    function test_getTokenUsdPrice1e8_reverts_when_price_above_ceiling() public {
        MockAggregatorV3 oracle = new MockAggregatorV3(8, int256(2e8));
        vm.expectRevert(bytes("Sale_PriceAboveCeiling"));
        harness.exposedGetTokenUsdPrice1e8Params(address(oracle), 24 hours, 1e8);
    }

    function test_getTokenUsdPrice1e8_reverts_when_stale() public {
        MockAggregatorV3 oracle = new MockAggregatorV3(8, int256(1e8));
        vm.warp(block.timestamp + 25 hours);
        vm.expectRevert(bytes("Sale_StalePrice"));
        harness.exposedGetTokenUsdPrice1e8Params(address(oracle), 24 hours, type(uint256).max);
    }
}
