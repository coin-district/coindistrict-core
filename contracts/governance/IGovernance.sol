//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

/**
 * @title IGovernance
 * @author CoinDistrict
 * @dev Version: 0.25.0
 * @notice Interface for governance contract that manages access control
 * @dev This interface allows 0.8.17 contracts to interact with 0.8.22 AccessManager-based governance
 * @dev Role IDs are defined off-chain in config/role-and-delays.json
 */
interface IGovernance {
    /**
     * @notice Check if a caller has permission to execute a function on a target contract
     * @param caller The address attempting to call the function
     * @param target The target contract address
     * @param selector The function selector (bytes4)
     * @return true if the caller has permission, false otherwise
     */
    function hasRole(address caller, address target, bytes4 selector) external view returns (bool);

    /**
     * @notice Check if a caller has permission to execute a function on a target contract with a delay
     * @param caller The address attempting to call the function
     * @param target The target contract address
     * @param selector The function selector (bytes4)
     * @return immediate true if the caller has permission immediately, false otherwise
     * @return setback delay in seconds if the caller has permission with a delay
     */
    function canCall(address caller, address target, bytes4 selector)
        external
        view
        returns (bool immediate, uint32 setback);

    /**
     * @notice Get the AccessManager address (for compatibility)
     * @return The AccessManager contract address
     */
    function accessManager() external view returns (address);
}
