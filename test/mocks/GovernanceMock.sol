// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {AccessManagerMock} from './AccessManagerMock.sol';

contract GovernanceMock {
    AccessManagerMock private immutable _ACCESS_MANAGER;

    constructor(address accessManager_) {
        _ACCESS_MANAGER = AccessManagerMock(accessManager_);
    }

    function hasRole(address caller, address target, bytes4 selector) external view returns (bool) {
        (bool immediate, ) = _ACCESS_MANAGER.canCall(caller, target, selector);
        return immediate;
    }

    function canCall(
        address caller,
        address target,
        bytes4 selector
    ) external view returns (bool immediate, uint32 delay) {
        return _ACCESS_MANAGER.canCall(caller, target, selector);
    }

    function accessManager() external view returns (address) {
        return address(_ACCESS_MANAGER);
    }
}
