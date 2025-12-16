// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

/// @dev Strongly-typed permission binding used in tests and scripts.
struct Permission {
    address target;
    bytes4 selector;
    uint64 roleId;
}
