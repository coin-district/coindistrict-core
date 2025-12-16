//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import '../interfaces/IAggregatorV3Interface.sol';

/**
 * @title MockAggregatorV3
 * @notice Mock Chainlink AggregatorV3Interface for testing
 */
contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 private immutable _decimals;
    int256 private _price;
    uint80 private _roundId;
    uint256 private _updatedAt;

    constructor(uint8 decimals_, int256 initialPrice) {
        _decimals = decimals_;
        _price = initialPrice;
        _roundId = 1;
        _updatedAt = block.timestamp;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return 'Mock Aggregator';
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80 _roundId
    )
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, block.timestamp, _updatedAt, _roundId);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, block.timestamp, _updatedAt, _roundId);
    }

    /**
     * @dev Update the price (for testing)
     */
    function updatePrice(int256 newPrice) external {
        _price = newPrice;
        _roundId++;
        _updatedAt = block.timestamp;
    }

    /**
     * @dev Update the timestamp (for testing staleness)
     */
    function updateTimestamp(uint256 newTimestamp) external {
        _updatedAt = newTimestamp;
    }
}
