//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IToken} from "@erc3643org/erc-3643/contracts/token/IToken.sol";
import {ITokenController} from "./ITokenController.sol";
import {IGovernance} from "./governance/IGovernance.sol";

/**
 * @title TokenController
 * @author CoinDistrict
 * @dev Version: 1.0.0-rc2
 * @notice Upgradeable controller that acts as ERC-3643 Token agent and provides granular capability gating
 */
contract TokenController is ITokenController, Initializable, UUPSUpgradeable {
    uint256 public constant INITIALIZED_BIT = 1 << 0;
    uint256 public constant PAUSABLE_BIT = 1 << 1;
    uint256 public constant MINTABLE_BIT = 1 << 2;
    uint256 public constant BURNABLE_BIT = 1 << 3;
    uint256 public constant FREEZABLE_BIT = 1 << 4;
    uint256 public constant FORCE_TRANSFERABLE_BIT = 1 << 5;
    uint256 public constant RECOVERABLE_BIT = 1 << 6;

    IGovernance public governance;

    /// @notice Capability bitmask by token
    mapping(address => uint256) public capabilitiesByToken;

    uint256[50] private __gap;

    modifier onlyGov() {
        _onlyGov();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address governance_) external initializer {
        __UUPSUpgradeable_init();
        if (governance_ == address(0)) revert InvalidGovernance();
        governance = IGovernance(governance_);
    }

    /**
     * @dev see {ITokenController.setTokenCapsInitial}
     */
    function setTokenCapsInitial(address token, uint256 caps) external onlyGov {
        if ((capabilitiesByToken[token] & INITIALIZED_BIT) != 0) revert CapsAlreadySet();
        // Always set INITIALIZED_BIT, even if caps is 0
        capabilitiesByToken[token] = caps | INITIALIZED_BIT;
        emit TokenCapabilitiesSet(token, capabilitiesByToken[token]);
    }

    /**
     * @dev see {ITokenController.setTokenCaps}
     */
    function setTokenCaps(address token, uint256 caps) external onlyGov {
        if ((capabilitiesByToken[token] & INITIALIZED_BIT) == 0) revert CapsNotInitialized();
        // Preserve INITIALIZED_BIT when updating
        capabilitiesByToken[token] = (caps & ~INITIALIZED_BIT) | INITIALIZED_BIT;
        emit TokenCapabilitiesSet(token, capabilitiesByToken[token]);
    }

    /**
     * @dev see {ITokenController.pause}
     */
    function pause(address token) external onlyGov {
        if (!isPausable(token)) revert PauseCapabilityDisabled();
        IToken(token).pause();
    }

    /**
     * @dev see {ITokenController.unpause}
     */
    function unpause(address token) external onlyGov {
        if (!isPausable(token)) revert PauseCapabilityDisabled();
        IToken(token).unpause();
    }

    /**
     * @dev see {ITokenController.mint}
     */
    function mint(address token, address to, uint256 amount) external onlyGov {
        if (!isMintable(token)) revert MintCapabilityDisabled();
        IToken(token).mint(to, amount);
    }

    /**
     * @dev see {ITokenController.burn}
     */
    function burn(address token, address user, uint256 amount) external onlyGov {
        if (!isBurnable(token)) revert BurnCapabilityDisabled();
        IToken(token).burn(user, amount);
    }

    /**
     * @dev see {ITokenController.forceTransfer}
     */
    function forceTransfer(address token, address from, address to, uint256 amount) external onlyGov {
        if (!isForceTransferable(token)) revert ForceTransferCapabilityDisabled();
        if (!IToken(token).forcedTransfer(from, to, amount)) revert ForcedTransferFailed();
    }

    /**
     * @dev see {ITokenController.setFrozen}
     */
    function setFrozen(address token, address user, bool freeze) external onlyGov {
        if (!isFreezable(token)) revert FreezeCapabilityDisabled();
        IToken(token).setAddressFrozen(user, freeze);
    }

    /**
     * @dev see {ITokenController.recover}
     */
    function recover(address token, address lostWallet, address newWallet, address investorOnchainId) external onlyGov {
        if (!isRecoverable(token)) revert RecoverCapabilityDisabled();
        if (!IToken(token).recoveryAddress(lostWallet, newWallet, investorOnchainId)) revert RecoveryFailed();
    }

    /**
     * @dev see {ITokenController.isPausable}
     */
    function isPausable(address token) public view returns (bool) {
        return (capabilitiesByToken[token] & PAUSABLE_BIT) != 0;
    }

    /**
     * @dev see {ITokenController.isMintable}
     */
    function isMintable(address token) public view returns (bool) {
        return (capabilitiesByToken[token] & MINTABLE_BIT) != 0;
    }

    /**
     * @dev see {ITokenController.isBurnable}
     */
    function isBurnable(address token) public view returns (bool) {
        return (capabilitiesByToken[token] & BURNABLE_BIT) != 0;
    }

    /**
     * @dev see {ITokenController.isFreezable}
     */
    function isFreezable(address token) public view returns (bool) {
        return (capabilitiesByToken[token] & FREEZABLE_BIT) != 0;
    }

    /**
     * @dev see {ITokenController.isForceTransferable}
     */
    function isForceTransferable(address token) public view returns (bool) {
        return (capabilitiesByToken[token] & FORCE_TRANSFERABLE_BIT) != 0;
    }

    /**
     * @dev see {ITokenController.isRecoverable}
     */
    function isRecoverable(address token) public view returns (bool) {
        return (capabilitiesByToken[token] & RECOVERABLE_BIT) != 0;
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
}
