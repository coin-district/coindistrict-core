//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {IToken} from '@erc3643org/erc-3643/contracts/token/IToken.sol';
import {ITokenController} from './ITokenController.sol';
import {IGovernance} from './governance/IGovernance.sol';

/**
 * @title TokenController
 * @author CoinDistrict
 * @dev Version: 0.23.1
 * @notice Upgradeable controller that acts as ERC-3643 Token agent and provides granular capability gating
 */
contract TokenController is ITokenController, Initializable, UUPSUpgradeable {
    // Governance interface
    IGovernance public governance;

    uint256 public constant INITIALIZED_BIT = 1 << 0;
    uint256 public constant PAUSABLE_BIT = 1 << 1;
    uint256 public constant MINTABLE_BIT = 1 << 2;
    uint256 public constant BURNABLE_BIT = 1 << 3;
    uint256 public constant FREEZABLE_BIT = 1 << 4;
    uint256 public constant FORCE_TRANSFERABLE_BIT = 1 << 5;
    uint256 public constant RECOVERABLE_BIT = 1 << 6;

    /// @notice Capability bitmask by token
    mapping(address => uint256) public capabilitiesByToken;

    uint256[50] private _gap;

    function initialize(address governance_) external initializer {
        __UUPSUpgradeable_init();
        require(governance_ != address(0), 'TokenController_InvalidGovernance');
        governance = IGovernance(governance_);
    }

    modifier onlyGov() {
        _onlyGov();
        _;
    }

    function _onlyGov() internal view {
        require(governance.hasRole(msg.sender, address(this), msg.sig), 'TokenController_NotAuthorized');
    }

    function _authorizeUpgrade(address /*newImplementation*/) internal view override {
        bytes4 selector = bytes4(keccak256('upgradeTo(address)'));
        require(governance.hasRole(msg.sender, address(this), selector), 'TokenController_NotAuthorized');
    }

    /**
     * @dev see {ITokenController.setTokenCapsInitial}
     */
    function setTokenCapsInitial(address token, uint256 caps) external onlyGov {
        require((capabilitiesByToken[token] & INITIALIZED_BIT) == 0, 'TokenController_CapsAlreadySet');
        // Always set INITIALIZED_BIT, even if caps is 0
        capabilitiesByToken[token] = caps | INITIALIZED_BIT;
        emit TokenCapabilitiesSet(token, capabilitiesByToken[token]);
    }

    /**
     * @dev see {ITokenController.setTokenCaps}
     */
    function setTokenCaps(address token, uint256 caps) external onlyGov {
        require((capabilitiesByToken[token] & INITIALIZED_BIT) != 0, 'TokenController_CapsNotInitialized');
        // Preserve INITIALIZED_BIT when updating
        capabilitiesByToken[token] = (caps & ~INITIALIZED_BIT) | INITIALIZED_BIT;
        emit TokenCapabilitiesSet(token, capabilitiesByToken[token]);
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

    /**
     * @dev see {ITokenController.pause}
     */
    function pause(address token) external onlyGov {
        require(isPausable(token), 'pause capability disabled');
        IToken(token).pause();
    }

    /**
     * @dev see {ITokenController.unpause}
     */
    function unpause(address token) external onlyGov {
        require(isPausable(token), 'pause capability disabled');
        IToken(token).unpause();
    }

    /**
     * @dev see {ITokenController.mint}
     */
    function mint(address token, address to, uint256 amount) external onlyGov {
        require(isMintable(token), 'mint capability disabled');
        IToken(token).mint(to, amount);
    }

    /**
     * @dev see {ITokenController.burn}
     */
    function burn(address token, address user, uint256 amount) external onlyGov {
        require(isBurnable(token), 'burn capability disabled');
        IToken(token).burn(user, amount);
    }

    /**
     * @dev see {ITokenController.forceTransfer}
     */
    function forceTransfer(address token, address from, address to, uint256 amount) external onlyGov {
        require(isForceTransferable(token), 'force transfer capability disabled');
        IToken(token).forcedTransfer(from, to, amount);
    }

    /**
     * @dev see {ITokenController.setFrozen}
     */
    function setFrozen(address token, address user, bool freeze) external onlyGov {
        require(isFreezable(token), 'freeze capability disabled');
        IToken(token).setAddressFrozen(user, freeze);
    }

    /**
     * @dev see {ITokenController.recover}
     */
    function recover(address token, address lostWallet, address newWallet, address investorOnchainId) external onlyGov {
        require(isRecoverable(token), 'recover capability disabled');
        IToken(token).recoveryAddress(lostWallet, newWallet, investorOnchainId);
    }
}
