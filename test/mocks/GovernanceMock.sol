// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import './AccessManagerMock.sol';

contract GovernanceMock {
    AccessManagerMock private immutable _accessManager;

    constructor(address accessManager_) {
        _accessManager = AccessManagerMock(accessManager_);
    }

    function hasRole(address caller, address target, bytes4 selector) external view returns (bool) {
        (bool immediate, ) = _accessManager.canCall(caller, target, selector);
        return immediate;
    }

    function canCall(
        address caller,
        address target,
        bytes4 selector
    ) external view returns (bool immediate, uint32 delay) {
        return _accessManager.canCall(caller, target, selector);
    }

    function accessManager() external view returns (address) {
        return address(_accessManager);
    }
}
