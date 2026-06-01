//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {ITREXFactory} from "@erc3643org/erc-3643/contracts/factory/ITREXFactory.sol";

/**
 * @title IFactory
 * @author CoinDistrict
 * @dev Version: 1.0.0-rc2
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
        uint256 indexed shareId, address indexed shareAddress, string shareName, string shareSymbol, uint8 shareDecimals
    );

    /**
     * @notice Emitted when the max supply compliance module address is updated
     * @param maxSupplyModule The new max supply compliance module address
     */
    event EditMaxSupplyModule(address maxSupplyModule);

    error InvalidGovernanceAddress();
    error InvalidTREXFactoryAddress();
    error InvalidSalesManagerAddress();
    error InvalidTokenControllerAddress();
    error InvalidMaxSupplyModuleAddress();
    error NotAuthorized();
    error NotOwnerOfTREXFactory();
    error MaxSupplyRequired();
    error MaxSupplyModuleNotSet();
    error CustomTokenAgentsNotAllowed();
    error Max5IRAgents();
    error IRSNot0OrOwnedByTREXFactory();
    error Max5ClaimTopics();
    error Max5Issuers();
    error ClaimIssuerLengthMismatch();
    error Max5TokenAgents();
    error SymbolAlreadyUsed();
    error SaltAlreadyUsed();

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

    /// @notice Parameters for {createShare}
    struct CreateShareParams {
        string name;
        string symbol;
        uint8 decimals;
        address owner;
        address[] tokenAgents;
        address[] irAgents;
        address irs;
        uint256[] claimTopics;
        address[] issuers;
        uint256[][] issuerClaims;
        uint256 maxSupply;
    }

    /**
     * @notice Deploy a standard ERC-3643 share (TokenController + SalesManager as the only agents,
     *         MaxSupplyModule enforced). `params.tokenAgents` must be empty.
     * @param params See {CreateShareParams}
     * @return tokenAddr The deployed share token address
     */
    function createShare(CreateShareParams calldata params) external returns (address tokenAddr);

    /**
     * @notice Forward deployment to TREXFactory with a custom salt
     * @dev Caller must hold PROTOCOL_ADMIN_ROLE and this contract must own TREXFactory.
     *      Token agents and compliance modules are forwarded exactly as supplied by the caller;
     *      no agents or modules are injected automatically.
     *      Intended only for highly trusted custom deployments — use createShare for standard issuance.
     * @param _salt Plain salt string; owner() will be appended internally for uniqueness
     * @param _tokenDetails Token parameters (see ITREXFactory.TokenDetails); tokenAgents.length <= 5
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
