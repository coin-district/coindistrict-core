//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

/**
 * @title IMaxSupplyModule
 * @author CoinDistrict
 * @dev Version: 0.24.5
 * @notice Mirror interface for {MaxSupplyModule} to allow external integrations and tooling.
 * See {IMaxSupplyModule} for usage and more details.
 * @dev All reads/writes are scoped to a given {ModularCompliance} binding (the compliance contract is used as key).
 */
interface IMaxSupplyModule {
    /**
     * @notice Owner-only (compliance) mutation to configure the maximum supply.
     * @dev Setting the value to zero removes the cap. Reverts if the new cap is below the tracked supply.
     * @param maxSupply The new circulating supply cap (0 = uncapped).
     */
    function setMaxSupply(uint256 maxSupply) external;

    /**
     * @notice Returns the configured maximum supply for a given compliance instance.
     * @dev A value of 0 denotes "uncapped".
     * @param compliance The {ModularCompliance} contract address.
     * @return maxSupply The max circulating supply allowed for this compliance.
     */
    function getMaxSupply(address compliance) external view returns (uint256 maxSupply);

    /**
     * @notice Returns the current circulating supply tracked by the module for the given compliance instance.
     * @param compliance The {ModularCompliance} contract address.
     * @return currentSupply The currently tracked circulating supply.
     */
    function getCurrentSupply(address compliance) external view returns (uint256 currentSupply);
}
