//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;
/**
 * @title Factory
 * @author CoinDistrict
 * @dev Version: 0.25.4
 * @notice Factory for deploying ERC-3643 shares with optional max supply enforcement
 * See {IFactory} for usage and more details.
 */

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TREXFactory} from "@erc3643org/erc-3643/contracts/factory/TREXFactory.sol";
import {ITREXFactory} from "@erc3643org/erc-3643/contracts/factory/ITREXFactory.sol";
import {IGovernance} from "./governance/IGovernance.sol";
import {IFactory} from "./IFactory.sol";

/**
 * @title Factory
 * @author CoinDistrict
 * @notice Factory for deploying ERC-3643 shares with optional max supply enforcement
 * See {IFactory} for usage and more details.
 */
interface IOwnableMinimal {
    function owner() external view returns (address);
}

contract Factory is IFactory, UUPSUpgradeable {
    TREXFactory private _trexFactory;
    address public salesManagerAddress;
    address public tokenControllerAddress; // always added as token agent
    address public maxSupplyModule; // optional module to enforce max supply
    uint256 public shareIdIndex;
    mapping(uint256 => address) public idToShare;
    mapping(address => uint256) public shareToId;
    mapping(bytes32 => bool) private _usedSymbols;

    // Governance interface
    IGovernance public governance;

    uint256[50] private __gap;

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
        require(_governance != address(0), "Factory_InvalidGovernanceAddress");
        require(_trexFactoryAddr != address(0), "Factory_InvalidTREXFactoryAddress");
        require(_salesManagerAddr != address(0), "Factory_InvalidSalesManagerAddress");
        require(_tokenControllerAddr != address(0), "Factory_InvalidTokenControllerAddress");
        require(_maxSupplyModuleAddr != address(0), "Factory_InvalidMaxSupplyModuleAddress");
        governance = IGovernance(_governance);
        _trexFactory = TREXFactory(_trexFactoryAddr);
        salesManagerAddress = _salesManagerAddr;
        tokenControllerAddress = _tokenControllerAddr;
        maxSupplyModule = _maxSupplyModuleAddr;
    }

    modifier onlyGov() {
        _onlyGov();
        _;
    }

    function _onlyGov() internal view {
        require(governance.hasRole(msg.sender, address(this), msg.sig), "Factory_NotAuthorized");
    }

    function _authorizeUpgrade(
        address /*newImplementation*/
    )
        internal
        view
        override
    {
        bytes4 selector = bytes4(keccak256("upgradeTo(address)"));
        require(governance.hasRole(msg.sender, address(this), selector), "Factory_NotAuthorized");
    }

    /**
     * @dev see {IFactory.createShare}
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
    ) external onlyGov returns (address) {
        require(isContractTrexFactoryOwner(), "Factory_NotOwnerOfTREXFactory");
        require(_maxSupply > 0, "Factory_MaxSupplyRequired");
        require(maxSupplyModule != address(0), "Factory_MaxSupplyModuleNotSet");

        // Standard deployments cannot include any extra token agents
        require(_tokenAgents.length == 0, "Factory_CustomTokenAgentsNotAllowed");

        require(_irAgents.length <= 5, "Factory_Max5IRAgents");
        require(
            _irs == address(0) || IOwnableMinimal(_irs).owner() == address(_trexFactory),
            "Factory_IRSNot0OrOwnedByTREXFactory"
        );
        // Claim/issuer constraints mirror TREXFactory
        require(_claimTopics.length <= 5, "Factory_Max5ClaimTopics");
        require(_issuers.length <= 5, "Factory_Max5Issuers");
        require(_issuerClaims.length == _issuers.length, "Factory_ClaimIssuerLengthMismatch");

        // Always exactly these 2 agents: TokenController (capability hub) and SalesManager (minting)
        address[] memory tokenAgents = new address[](2);
        tokenAgents[0] = tokenControllerAddress;
        tokenAgents[1] = salesManagerAddress;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: _owner,
            name: _name,
            symbol: _symbol,
            decimals: _decimals,
            irs: _irs,
            ONCHAINID: address(0),
            irAgents: _irAgents,
            tokenAgents: tokenAgents,
            complianceModules: new address[](1),
            complianceSettings: new bytes[](1)
        });

        tokenDetails.complianceModules[0] = maxSupplyModule;
        tokenDetails.complianceSettings[0] = abi.encodeWithSignature("setMaxSupply(uint256)", _maxSupply);

        ITREXFactory.ClaimDetails memory claimDetails =
            ITREXFactory.ClaimDetails({claimTopics: _claimTopics, issuers: _issuers, issuerClaims: _issuerClaims});

        bytes32 saltHash = keccak256(abi.encode(_name, _symbol));
        string memory salt = string(abi.encodePacked(saltHash));

        address tokenAddr = _deployWithAuthorityBoundSalt(salt, tokenDetails, claimDetails);
        return tokenAddr;
    }

    /**
     * @dev see {IFactory.deployShareSuite}
     */
    function deployShareSuite(
        string memory _salt,
        ITREXFactory.TokenDetails memory _tokenDetails,
        ITREXFactory.ClaimDetails memory _claimDetails
    ) public onlyGov returns (address) {
        require(isContractTrexFactoryOwner(), "Factory_NotOwnerOfTREXFactory");
        require(_tokenDetails.tokenAgents.length <= 5, "Factory_Max5TokenAgents");
        return _deployWithAuthorityBoundSalt(_salt, _tokenDetails, _claimDetails);
    }

    /**
     * @dev see {IFactory.isContractTrexFactoryOwner}
     */
    function isContractTrexFactoryOwner() public view returns (bool) {
        return _trexFactory.owner() == address(this);
    }

    /**
     * @dev see {IFactory.editMaxSupplyModule}
     */
    function editMaxSupplyModule(address _module) public onlyGov {
        maxSupplyModule = _module;
        emit EditMaxSupplyModule(_module);
    }

    /// @dev Internal deployment wrapper adding authority() to salt and indexing the result
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
        require(!_usedSymbols[_symbolKey], "Factory_SymbolAlreadyUsed");

        string memory authorityBoundSalt = string(abi.encodePacked(_salt, address(governance), block.chainid));
        require(_trexFactory.getToken(authorityBoundSalt) == address(0), "Factory_SaltAlreadyUsed");

        _trexFactory.deployTREXSuite(authorityBoundSalt, _tokenDetails, _claimDetails);
        address tokenAddr = _trexFactory.getToken(authorityBoundSalt);

        unchecked {
            shareIdIndex++;
        }
        idToShare[shareIdIndex] = tokenAddr;
        shareToId[tokenAddr] = shareIdIndex;
        _usedSymbols[_symbolKey] = true;
        emit ShareCreated(shareIdIndex, tokenAddr, _tokenDetails.name, _tokenDetails.symbol, _tokenDetails.decimals);
        return tokenAddr;
    }

    /**
     * @dev see {IFactory.trexFactory}
     */
    function trexFactory() public view override returns (address) {
        return address(_trexFactory);
    }
}
