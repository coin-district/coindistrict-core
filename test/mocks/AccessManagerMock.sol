// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

contract AccessManagerMock {
    struct TargetRole {
        address target;
        bytes4 selector;
        uint64 roleId;
    }

    mapping(uint64 => mapping(address => bool)) public hasRole;
    mapping(address => mapping(bytes4 => uint64)) public targetRole;

    bool private _canCallOverrideActive;
    bool private _canCallImmediate;
    uint32 private _canCallDelay;

    event RoleGranted(uint64 indexed roleId, address indexed account);
    event RoleRevoked(uint64 indexed roleId, address indexed account);
    event TargetFunctionRoleSet(address indexed target, bytes4 indexed selector, uint64 roleId);

    function setTargetFunctionRole(address target, bytes4[] memory selectors, uint64 roleId) external {
        for (uint256 i = 0; i < selectors.length; i++) {
            targetRole[target][selectors[i]] = roleId;
            emit TargetFunctionRoleSet(target, selectors[i], roleId);
        }
    }

    function grantRole(
        uint64 roleId,
        address account,
        uint64 /*delay*/
    )
        external
    {
        hasRole[roleId][account] = true;
        emit RoleGranted(roleId, account);
    }

    function revokeRole(uint64 roleId, address account) external {
        hasRole[roleId][account] = false;
        emit RoleRevoked(roleId, account);
    }

    function setCanCallReturn(bool immediate, uint32 delay) external {
        _canCallOverrideActive = true;
        _canCallImmediate = immediate;
        _canCallDelay = delay;
    }

    function clearCanCallReturn() external {
        _canCallOverrideActive = false;
    }

    function canCall(address caller, address target, bytes4 selector)
        external
        view
        returns (bool immediate, uint32 delay)
    {
        if (_canCallOverrideActive) {
            return (_canCallImmediate, _canCallDelay);
        }
        uint64 roleId = targetRole[target][selector];
        return (hasRole[roleId][caller], 0);
    }
}
