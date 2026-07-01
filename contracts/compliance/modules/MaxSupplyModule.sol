//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {AbstractModule} from "@erc3643org/erc-3643/contracts/compliance/modular/modules/AbstractModule.sol";
import {IMaxSupplyModule} from "./IMaxSupplyModule.sol";

/**
 * @title MaxSupplyModule
 * @author CoinDistrict
 * @dev Version: 1.0.0-rc4-low-delays
 * @notice MaxSupplyModule for enforcing max supply on ERC-3643 shares
 * See {IMaxSupplyModule} for usage and more details.
 */
contract MaxSupplyModule is AbstractModule {
    mapping(address => uint256) private _maxSupplyByCompliance;
    mapping(address => uint256) private _currentSupplyByCompliance;

    // --- Owner (compliance) configuration ---

    function setMaxSupply(uint256 maxSupply) external onlyComplianceCall {
        uint256 currentSupply = _currentSupplyByCompliance[msg.sender];
        if (maxSupply != 0 && maxSupply < currentSupply) revert IMaxSupplyModule.MaxSupplyBelowCurrentSupply();
        _maxSupplyByCompliance[msg.sender] = maxSupply;
    }

    // --- IModule impl ---

    function moduleTransferAction(
        address,
        /*_from*/
        address,
        /*_to*/
        uint256 /*_value*/
    )
        external
        override
        onlyComplianceCall
    {}

    function moduleMintAction(
        address,
        /*_to*/
        uint256 _value
    )
        external
        override
        onlyComplianceCall
    {
        _currentSupplyByCompliance[msg.sender] += _value;
    }

    function moduleBurnAction(
        address,
        /*_from*/
        uint256 _value
    )
        external
        override
        onlyComplianceCall
    {
        uint256 cur = _currentSupplyByCompliance[msg.sender];
        // underflow would revert automatically if inconsistent burns occur
        _currentSupplyByCompliance[msg.sender] = cur - _value;
    }

    // --- Views ---

    /**
     * @dev The check blocks minting (from == address(0)) if current + value exceeds max.
     */
    function moduleCheck(
        address _from,
        address,
        /*_to*/
        uint256 _value,
        address _compliance
    )
        external
        view
        override
        onlyBoundCompliance(_compliance)
        returns (bool)
    {
        if (_from == address(0)) {
            uint256 maxSupply = _maxSupplyByCompliance[_compliance];
            if (maxSupply == 0) {
                return true; // 0 means uncapped
            }
            uint256 cur = _currentSupplyByCompliance[_compliance];
            if (cur + _value > maxSupply) {
                return false;
            }
        }
        return true;
    }

    function getMaxSupply(address compliance) external view returns (uint256) {
        return _maxSupplyByCompliance[compliance];
    }

    function getCurrentSupply(address compliance) external view returns (uint256) {
        return _currentSupplyByCompliance[compliance];
    }

    // --- Pures ---

    function isPlugAndPlay() external pure override returns (bool) {
        return true;
    }

    function canComplianceBind(
        address /*_compliance*/
    )
        external
        pure
        override
        returns (bool)
    {
        return true;
    }

    function name() external pure override returns (string memory _name) {
        return "MaxSupplyModule";
    }
}
