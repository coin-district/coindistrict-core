// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {AccessManagerMock} from "./mocks/AccessManagerMock.sol";

// Helper: deploys a Governance via vm.getCode so the test file can stay at 0.8.17
// while Governance.sol uses 0.8.22. The external call lets vm.expectRevert intercept
// the constructor revert and inspect its reason string.
contract GovernanceDeployer {
    function deploy(bytes memory bytecode) external {
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
            if iszero(deployed) {
                let size := returndatasize()
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }
    }
}

contract GovernanceTest is Test {
    AccessManagerMock private manager;
    GovernanceDeployer private deployer;

    function setUp() public {
        manager = new AccessManagerMock();
        deployer = new GovernanceDeployer();
    }

    // Constructor

    function test_constructor_rejects_zero_access_manager() public {
        bytes memory creation = vm.getCode("contracts/governance/Governance.sol:Governance");
        bytes memory bytecode = abi.encodePacked(creation, abi.encode(address(0)));
        vm.expectRevert(bytes("Governance_InvalidAccessManager"));
        deployer.deploy(bytecode);
    }

    function test_constructor_stores_access_manager() public {
        IGovernance gov = IGovernance(_deployGovernance(address(manager)));
        assertEq(gov.accessManager(), address(manager));
    }

    // hasRole

    function test_hasRole_returns_true_when_canCall_immediate() public {
        IGovernance gov = IGovernance(_deployGovernance(address(manager)));
        address caller = address(0x123);
        address target = address(0x456);
        bytes4 selector = bytes4(keccak256("someFunction()"));
        uint64 roleId = 1;

        manager.setTargetFunctionRole(target, _toSingle(selector), roleId);
        manager.grantRole(roleId, caller, 0);

        assertTrue(gov.hasRole(caller, target, selector));
    }

    function test_hasRole_returns_false_when_canCall_delayed() public {
        manager.setCanCallReturn(false, 100);
        IGovernance gov = IGovernance(_deployGovernance(address(manager)));
        address caller = address(0x123);
        address target = address(0x456);
        bytes4 selector = bytes4(keccak256("someFunction()"));

        assertFalse(gov.hasRole(caller, target, selector));
    }

    function test_hasRole_returns_true_after_delay_expires() public {
        address caller = address(0x123);
        address target = address(0x456);
        bytes4 selector = bytes4(keccak256("someFunction()"));
        uint64 roleId = 1;

        manager.setTargetFunctionRole(target, _toSingle(selector), roleId);
        manager.grantRole(roleId, caller, 0);
        manager.setCanCallReturn(false, 100);

        IGovernance gov = IGovernance(_deployGovernance(address(manager)));
        assertFalse(gov.hasRole(caller, target, selector));

        vm.warp(block.timestamp + 100);
        manager.clearCanCallReturn();

        assertTrue(gov.hasRole(caller, target, selector));
    }

    // canCall

    function test_canCall_proxies_delayed_access_manager_return() public {
        manager.setCanCallReturn(false, 100);
        IGovernance gov = IGovernance(_deployGovernance(address(manager)));
        (bool immediate, uint32 delay) = gov.canCall(address(0x1), address(0x2), bytes4(keccak256("x()")));
        assertFalse(immediate);
        assertEq(delay, 100);
    }

    function test_canCall_transitions_from_delayed_to_immediate_after_delay() public {
        address caller = address(0x123);
        address target = address(0x456);
        bytes4 selector = bytes4(keccak256("someFunction()"));
        uint64 roleId = 1;

        manager.setTargetFunctionRole(target, _toSingle(selector), roleId);
        manager.grantRole(roleId, caller, 0);
        manager.setCanCallReturn(false, 100);

        IGovernance gov = IGovernance(_deployGovernance(address(manager)));

        (bool immediate, uint32 delay) = gov.canCall(caller, target, selector);
        assertFalse(immediate);
        assertEq(delay, 100);

        vm.warp(block.timestamp + 100);
        manager.clearCanCallReturn();

        (immediate, delay) = gov.canCall(caller, target, selector);
        assertTrue(immediate);
        assertEq(delay, 0);
    }

    function test_canCall_proxies_access_manager() public {
        IGovernance gov = IGovernance(_deployGovernance(address(manager)));
        address caller = address(0x123);
        address target = address(0x456);
        bytes4 selector = bytes4(keccak256("someFunction()"));
        uint64 roleId = 1;

        manager.setTargetFunctionRole(target, _toSingle(selector), roleId);
        manager.grantRole(roleId, caller, 0);

        (bool immediate, uint32 delay) = gov.canCall(caller, target, selector);
        assertTrue(immediate);
        assertEq(delay, 0);
    }

    // Helpers

    function _deployGovernance(address accessManager) internal returns (address deployed) {
        bytes memory creation = vm.getCode("contracts/governance/Governance.sol:Governance");
        bytes memory bytecode = abi.encodePacked(creation, abi.encode(accessManager));
        assembly ("memory-safe") {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "Governance deploy failed");
    }

    function _toSingle(bytes4 selector) internal pure returns (bytes4[] memory arr) {
        arr = new bytes4[](1);
        arr[0] = selector;
    }
}
