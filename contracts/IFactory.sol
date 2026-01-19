//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {ITREXFactory} from '@erc3643org/erc-3643/contracts/factory/ITREXFactory.sol';

/**
 * @title IFactory
 * @author CoinDistrict
 * @dev Version: 0.24.2
 * @notice Interface for the Factory contract
 * @dev For role values, see Governance.sol constants
 * See {Factory} for usage and more details.
 */
interface IFactory {
    /**
     * @notice Emitted when a new share is created
     * @param shareId The ID of the share
     * @param shareAddress The address of the share
     * @param shareName The name of the share
     * @param shareSymbol The symbol of the share
     * @param shareDecimals The decimals of the share
     */
    event ShareCreated(
        uint256 indexed shareId,
        address indexed shareAddress,
        string shareName,
        string shareSymbol,
        uint8 shareDecimals
    );

    /**
     * @notice Emitted when the max supply compliance module address is updated
     * @param maxSupplyModule The new max supply compliance module address
     */
    event EditMaxSupplyModule(address maxSupplyModule);

    /**
     * @notice Returns the address of the TREXFactory
     * @return The address of the TREXFactory
     */
    function trexFactory() external view returns (address);

    /**
     * @notice Returns the SalesManager address automatically added as token agent
     */
    function salesManagerAddress() external view returns (address);

    /**
     * @notice Returns the TokenController address automatically added as token agent
     */
    function tokenControllerAddress() external view returns (address);

    /**
     * @notice Returns the index of the share
     * @return The index of the share
     */
    function shareIdIndex() external view returns (uint256);

    /**
     * @notice Returns the address of the share
     * @param id The ID of the share
     * @return The address of the share
     */
    function idToShare(uint256 id) external view returns (address);

    /**
     * @notice Returns the ID of the share
     * @param token The address of the share
     * @return The ID of the share
     */
    function shareToId(address token) external view returns (uint256);

    /**
     * @notice Returns the currently configured MaxSupplyModule implementation address
     */
    function maxSupplyModule() external view returns (address);

    /**
     * @notice Deploy a new token suite (share) with minimal required parameters
     * @dev For role values, see Governance.sol constants
     * @dev If _irs is zero, TREXFactory will deploy a fresh IRS; otherwise IRS must be owned by TREXFactory
     * @dev function automatically sets token agents to {tokenController, salesManager}
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _decimals Token decimals
     * @param _owner Owner of all deployed share contracts
     * @param _tokenAgents Must be empty (custom token agents require deployShareSuite)
     * @param _irAgents Identity registry agent addresses (max 5)
     * @param _irs Optional shared IdentityRegistryStorage address (0 to deploy new)
     * @param _claimTopics Required claim topics for verification (max 5)
     * @param _issuers Trusted issuers ONCHAINID addresses (max 5)
     * @param _issuerClaims Per-issuer allowed claim topics (length must match issuers)
     * @param _maxSupply Circulating supply cap for the share; must be greater than zero
     * @return tokenAddr The deployed token address
     * @dev If _irs is zero, TREXFactory will deploy a fresh IRS; otherwise IRS must be owned by TREXFactory
     */
    function createShare(
        string calldata _name,
        string calldata _symbol,
        uint8 _decimals,
        address _owner,
        address[] calldata _tokenAgents,
        address[] calldata _irAgents,
        address _irs,
        uint256[] calldata _claimTopics,
        address[] calldata _issuers,
        uint256[][] calldata _issuerClaims,
        uint256 _maxSupply
    ) external returns (address);

    /**
     * @notice Forward deployment to TREXFactory with a custom salt
     * @dev Caller must be owner and this contract must own TREXFactory
     * @dev function automatically adds salesManager as a token agent
     * @param _salt Plain salt string; owner() will be appended internally for uniqueness
     * @param _tokenDetails Token parameters (see ITREXFactory.TokenDetails), except tokenAgents <= 4 (salesManager is added automatically)
     * @param _claimDetails Claim/issuer parameters (see ITREXFactory.ClaimDetails)
     * @return tokenAddr The deployed token address
     */
    function deployShareSuite(
        string memory _salt,
        ITREXFactory.TokenDetails memory _tokenDetails,
        ITREXFactory.ClaimDetails memory _claimDetails
    ) external returns (address);

    /// @notice Returns true if this contract is the owner of TREXFactory
    function isContractTrexFactoryOwner() external view returns (bool);

    /**
     * @notice Set the MaxSupplyModule implementation used for new share deployments
     * @param _module The new MaxSupplyModule implementation address
     */
    function editMaxSupplyModule(address _module) external;
}
