//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;
/**
 * @title Factory
 * @author CoinDistrict
 * @dev Version: 1.0.0-rc1
 * @notice Factory for deploying ERC-3643 shares with optional max supply enforcement
 * See {IFactory} for usage and more details.
 */

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TREXFactory} from "@erc3643org/erc-3643/contracts/factory/TREXFactory.sol";
import {ITREXFactory} from "@erc3643org/erc-3643/contracts/factory/ITREXFactory.sol";
import {IGovernance} from "./governance/IGovernance.sol";
import {IFactory} from "./IFactory.sol";
import {IOwnableMinimal} from "./interfaces/IOwnableMinimal.sol";

contract Factory is IFactory, UUPSUpgradeable {
    TREXFactory private _trexFactory;
    IGovernance public governance;
    address public salesManagerAddress;
    address public tokenControllerAddress; // always added as token agent
    address public maxSupplyModule; // optional module to enforce max supply
    uint256 public shareIdIndex;
    mapping(uint256 => address) public idToShare;
    mapping(address => uint256) public shareToId;
    mapping(bytes32 => bool) private _usedSymbols;

    uint256[50] private __gap;

    modifier onlyGov() {
        _onlyGov();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _trexFactoryAddr Address of the TREXFactory this contract must own
     * @param _salesManagerAddr Address of the SalesManager contract
     * @param _tokenControllerAddr Address of the TokenController contract (always added as token agent)
     * @param _maxSupplyModuleAddr Address of the MaxSupplyModule
     * @param _governance Address of the Governance contract
     */
    function initialize(
        address _trexFactoryAddr,
        address _salesManagerAddr,
        address _tokenControllerAddr,
        address _maxSupplyModuleAddr,
        address _governance
    ) external initializer {
        __UUPSUpgradeable_init();
        if (_governance == address(0)) revert InvalidGovernanceAddress();
        if (_trexFactoryAddr == address(0)) revert InvalidTREXFactoryAddress();
        if (_salesManagerAddr == address(0)) revert InvalidSalesManagerAddress();
        if (_tokenControllerAddr == address(0)) revert InvalidTokenControllerAddress();
        if (_maxSupplyModuleAddr == address(0)) revert InvalidMaxSupplyModuleAddress();
        governance = IGovernance(_governance);
        _trexFactory = TREXFactory(_trexFactoryAddr);
        salesManagerAddress = _salesManagerAddr;
        tokenControllerAddress = _tokenControllerAddr;
        maxSupplyModule = _maxSupplyModuleAddr;
    }

    /**
     * @dev see {IFactory.createShare}
     */
    function createShare(IFactory.CreateShareParams calldata params) external onlyGov returns (address) {
        if (!isContractTrexFactoryOwner()) revert NotOwnerOfTREXFactory();
        if (params.maxSupply == 0) revert MaxSupplyRequired();
        if (maxSupplyModule == address(0)) revert MaxSupplyModuleNotSet();

        // Standard deployments cannot include any extra token agents
        if (params.tokenAgents.length != 0) revert CustomTokenAgentsNotAllowed();

        if (params.irAgents.length > 5) revert Max5IRAgents();
        if (params.irs != address(0) && IOwnableMinimal(params.irs).owner() != address(_trexFactory)) {
            revert IRSNot0OrOwnedByTREXFactory();
        }

        // Claim/issuer constraints mirror TREXFactory
        if (params.claimTopics.length > 5) revert Max5ClaimTopics();
        if (params.issuers.length > 5) revert Max5Issuers();
        if (params.issuerClaims.length != params.issuers.length) revert ClaimIssuerLengthMismatch();

        // Always exactly these 2 agents: TokenController (capability hub) and SalesManager (minting)
        address[] memory tokenAgents = new address[](2);
        tokenAgents[0] = tokenControllerAddress;
        tokenAgents[1] = salesManagerAddress;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: params.owner,
            name: params.name,
            symbol: params.symbol,
            decimals: params.decimals,
            irs: params.irs,
            ONCHAINID: address(0),
            irAgents: params.irAgents,
            tokenAgents: tokenAgents,
            complianceModules: new address[](1),
            complianceSettings: new bytes[](1)
        });

        tokenDetails.complianceModules[0] = maxSupplyModule;
        tokenDetails.complianceSettings[0] = abi.encodeWithSignature("setMaxSupply(uint256)", params.maxSupply);

        ITREXFactory.ClaimDetails memory claimDetails = ITREXFactory.ClaimDetails({
            claimTopics: params.claimTopics, issuers: params.issuers, issuerClaims: params.issuerClaims
        });

        bytes32 saltHash = keccak256(abi.encode(params.name, params.symbol));
        string memory salt = string(abi.encodePacked(saltHash));

        return _deployWithAuthorityBoundSalt(salt, tokenDetails, claimDetails);
    }

    /**
     * @dev see {IFactory.deployShareSuite}
     */
    function deployShareSuite(
        string memory _salt,
        ITREXFactory.TokenDetails memory _tokenDetails,
        ITREXFactory.ClaimDetails memory _claimDetails
    ) public onlyGov returns (address) {
        if (!isContractTrexFactoryOwner()) {
            revert NotOwnerOfTREXFactory();
        }

        if (_tokenDetails.tokenAgents.length > 5) revert Max5TokenAgents();
        return _deployWithAuthorityBoundSalt(_salt, _tokenDetails, _claimDetails);
    }

    /**
     * @dev see {IFactory.editMaxSupplyModule}
     */
    function editMaxSupplyModule(address _module) public onlyGov {
        maxSupplyModule = _module;
        emit EditMaxSupplyModule(_module);
    }

    /**
     * @dev see {IFactory.trexFactory}
     */
    function trexFactory() public view override returns (address) {
        return address(_trexFactory);
    }

    /**
     * @dev see {IFactory.isContractTrexFactoryOwner}
     */
    function isContractTrexFactoryOwner() public view returns (bool) {
        return _trexFactory.owner() == address(this);
    }

    function _onlyGov() internal view {
        if (!governance.hasRole(msg.sender, address(this), msg.sig)) revert NotAuthorized();
    }

    function _authorizeUpgrade(
        address /*newImplementation*/
    )
        internal
        view
        override
    {
        if (!governance.hasRole(msg.sender, address(this), msg.sig)) revert NotAuthorized();
    }

    /// @dev Internal deployment wrapper adding authority() to salt and indexing the result.
    function _deployWithAuthorityBoundSalt(
        string memory _salt,
        ITREXFactory.TokenDetails memory _tokenDetails,
        ITREXFactory.ClaimDetails memory _claimDetails
    ) internal returns (address) {
        bytes memory symbolBytes = bytes(_tokenDetails.symbol);
        bytes32 _symbolKey;
        assembly ("memory-safe") {
            _symbolKey := keccak256(add(symbolBytes, 0x20), mload(symbolBytes))
        }

        if (_usedSymbols[_symbolKey]) revert SymbolAlreadyUsed();
        _usedSymbols[_symbolKey] = true;

        string memory authorityBoundSalt = string(abi.encodePacked(_salt, address(governance), block.chainid));
        if (_trexFactory.getToken(authorityBoundSalt) != address(0)) revert SaltAlreadyUsed();

        _trexFactory.deployTREXSuite(authorityBoundSalt, _tokenDetails, _claimDetails);
        address tokenAddr = _trexFactory.getToken(authorityBoundSalt);

        unchecked {
            shareIdIndex++;
        }

        idToShare[shareIdIndex] = tokenAddr;
        shareToId[tokenAddr] = shareIdIndex;
        emit ShareCreated(shareIdIndex, tokenAddr, _tokenDetails.name, _tokenDetails.symbol, _tokenDetails.decimals);
        return tokenAddr;
    }
}
