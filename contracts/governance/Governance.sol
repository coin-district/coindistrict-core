//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.22;

import {AccessManager} from '@openzeppelin/contracts-v5/access/manager/AccessManager.sol';

/**
 * @title Governance
 * @author CoinDistrict
 * @dev Version: 0.22.0
 * @notice Centralized governance contract using OpenZeppelin AccessManager
 * @dev Compiled with Solidity 0.8.22 to use AccessManager from OpenZeppelin 5.x
 * This contract acts as a bridge between 0.8.17 protocol contracts and 0.8.22 AccessManager
 *
 * Note: Interface is defined separately in IGovernance.sol (0.8.17) for protocol contracts.
 * This contract implements the same interface but cannot import it due to version mismatch.
 */
contract Governance {
    AccessManager private immutable _ACCESS_MANAGER;

    // Role IDs (uint64)
    uint64 public constant ADMIN_ROLE = 0;
    uint64 public constant UPGRADER_ROLE = 1;
    uint64 public constant SHARE_DEPLOYER_ROLE = 2;
    uint64 public constant SALES_CONFIG_ROLE = 3;
    uint64 public constant SALES_OPERATOR_ROLE = 4;
    uint64 public constant FUNDS_ADMIN_ROLE = 5;
    uint64 public constant FIAT_ORDER_ROLE = 6;
    uint64 public constant PAUSER_ROLE = 7;
    uint64 public constant MINTER_ROLE = 8;
    uint64 public constant BURNER_ROLE = 9;
    uint64 public constant FREEZER_ROLE = 10;
    uint64 public constant FORCE_ROLE = 11;
    uint64 public constant RECOVERY_ROLE = 12;

    /**
     * @notice Initialize the Governance contract with an AccessManager
     * @param accessManager_ The AccessManager contract address
     */
    constructor(address accessManager_) {
        require(accessManager_ != address(0), 'Governance_InvalidAccessManager');
        _ACCESS_MANAGER = AccessManager(accessManager_);
    }

    /**
     * @dev See {IGovernance.hasRole}
     */
    function hasRole(address caller, address target, bytes4 selector) external view returns (bool) {
        (bool immediate, ) = _ACCESS_MANAGER.canCall(caller, target, selector);
        return immediate;
    }

    /**
     * @dev See {IGovernance.canCall}
     */
    function canCall(
        address caller,
        address target,
        bytes4 selector
    ) external view returns (bool immediate, uint32 delay) {
        return _ACCESS_MANAGER.canCall(caller, target, selector);
    }

    /**
     * @dev See {IGovernance.accessManager}
     */
    function accessManager() external view returns (address) {
        return address(_ACCESS_MANAGER);
    }
}
