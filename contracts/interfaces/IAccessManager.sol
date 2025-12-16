// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

/// @notice Minimal interface for OZ AccessManager (v5) used by 0.8.17 contracts/tests.
interface IAccessManager {
    function setTargetFunctionRole(
        address target,
        bytes4[] calldata selectors,
        uint64 roleId
    ) external;

    function grantRole(uint64 roleId, address account, uint32 delay) external;

    function revokeRole(uint64 roleId, address account) external;
}

