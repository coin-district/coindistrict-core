//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.22;

import {AccessManager} from "@openzeppelin/contracts-v5/access/manager/AccessManager.sol";

/**
 * @title Governance
 * @author CoinDistrict
 * @dev Version: 1.0.2
 * @notice Centralized governance contract using OpenZeppelin AccessManager
 * @dev Compiled with Solidity 0.8.22 to use AccessManager from OpenZeppelin 5.x
 * This contract acts as a bridge between 0.8.17 protocol contracts and 0.8.22 AccessManager
 *
 * Note: Interface is defined separately in IGovernance.sol (0.8.17) for protocol contracts.
 * This contract implements the same interface but cannot import it due to version mismatch.
 */
contract Governance {
    /// @notice Reverts when the AccessManager address provided to the constructor is zero
    error InvalidAccessManager();

    AccessManager private immutable _ACCESS_MANAGER;

    /**
     * @notice Initialize the Governance contract with an AccessManager
     * @param accessManager_ The AccessManager contract address
     */
    constructor(address accessManager_) {
        if (accessManager_ == address(0)) revert InvalidAccessManager();
        _ACCESS_MANAGER = AccessManager(accessManager_);
    }

    /**
     * @dev See {IGovernance.hasRole}
     */
    function hasRole(address caller, address target, bytes4 selector) external view returns (bool) {
        (bool immediate,) = _ACCESS_MANAGER.canCall(caller, target, selector);
        return immediate;
    }

    /**
     * @dev See {IGovernance.canCall}
     */
    function canCall(address caller, address target, bytes4 selector)
        external
        view
        returns (bool immediate, uint32 delay)
    {
        return _ACCESS_MANAGER.canCall(caller, target, selector);
    }

    /**
     * @dev See {IGovernance.accessManager}
     */
    function accessManager() external view returns (address) {
        return address(_ACCESS_MANAGER);
    }
}
